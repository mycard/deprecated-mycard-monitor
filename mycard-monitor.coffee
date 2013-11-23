settings = null

try
  settings = require './config.json'
catch
  settings = {
    interval: parseInt process.env.inteval
    database: process.env.database
    port: process.env.port
    mail: {
      service: process.env.mail_service
      auth: {
        user: process.env.mail_auth_user
        pass: process.env.mail_auth_pass
      }
    }
    xmpp: {
      jid: process.env.xmpp_jid
      password: process.env.xmpp_password
    }
  }

console.log settings

url = require 'url'
net = require 'net'
http = require 'http'

request = require 'request'
nodemailer = require "nodemailer"
xmpp = require 'node-xmpp'
dns = require 'native-dns'
WebSocketClient = require("websocket").client
MongoClient = require('mongodb').MongoClient

smtp = nodemailer.createTransport "SMTP",settings.mail

xmpp_client = new xmpp.Client(settings.xmpp)

#main
MongoClient.connect settings.database, (err, db)->
  throw err if err

  apps_collection = db.collection('apps')
  logs_collection = db.collection('logs')

  log = (app, alive, message)->
    console.log "#{app.name} #{alive} #{message}"
    if alive != app.alive
      date = new Date()
      logs_collection.insert {app: app._id, alive: alive, message: message, created_at: date}, (err)->
        throw err if err

      if alive
        console.log "#{app.name} up #{message}"
        #邮件通知
        smtp.sendMail
          from: "萌卡监控 <zh99998@gmail.com>"
          to: "zh99998@gmail.com",
          subject: "萌卡监控 - #{app.name} 恢复可用 (#{message})"
          text: "#{message}"
          html: "#{message}"

        #xmpp通知
        stanza = new xmpp.Element('message',{ to: 'zh99998@gmail.com', type: 'chat' }).c('body').t(
          "萌卡监控 - #{app.name} 恢复可用 (#{message})"
        )
        xmpp_client.send(stanza)

        apps_collection.update {_id:app._id}, {$set:{alive:alive, retries:0}}, (err)->
          throw err if err

      else if app.retries >= 5
        console.log "#{app.name} down #{message}"

        #邮件通知
        smtp.sendMail
          from: "萌卡监控 <zh99998@gmail.com>"
          to: "zh99998@gmail.com",
          subject: "萌卡监控 - #{app.name} 不可用 (#{message})"
          text: "#{message}"
          html: "#{message}"

        #xmpp通知
        stanza = new xmpp.Element('message',{ to: 'zh99998@gmail.com', type: 'chat' }).c('body').t(
          "萌卡监控 - #{app.name} 不可用 (#{message})"
        )
        xmpp_client.send(stanza)

        apps_collection.update {_id:app._id}, {$set:{alive:alive}}, (err)->
          throw err if err

      else
        console.log "#{app.name} retry#{app.retries} #{message}"
        apps_collection.update {_id:app._id}, {$inc:{retries:1}}, (err)->
          throw err if err

  setInterval ->
    apps_collection.find().toArray (err, apps)->
      apps.forEach (app)->
        url_parsed = url.parse app.url
        switch url_parsed.protocol
          when 'ws:', 'wss:'
            client = new WebSocketClient()
            client.on "connectFailed", (error) ->
              log(app, false, error)

            client.on "connect", (connection) ->
              this.close()
              log(app, true, "WebSocket连接成功")

            client.connect app.url
          when 'http:', 'https:'
            request
              url: app.url
              timeout: 10000
              strictSSL: true
            , (err, response, body)->
              if err #http失败
                log(app, false, err)
              else if response.statusCode >= 400 #http成功，但返回了4xx或5xx
                log(app, false, "HTTP #{response.statusCode} #{http.STATUS_CODES[response.statusCode]}")
              else #ok
                log(app, true, "HTTP #{response.statusCode} #{http.STATUS_CODES[response.statusCode]}")
          when 'xmpp:'
          #client = new xmpp.Client()
          #client.on 'error', (error)->
          #  console.error(error)
            null
          when 'tcp:'
            client = net.connect port:url_parsed.port, host:url_parsed.hostname, ->
              client.end()
              log(app, true, "TCP连接成功")
            client.on 'error', (error)->
              log(app, false, "error")
          when 'dns:'
            question = dns.Question
              name: url_parsed.pathname.slice(1)
            for dnsquery in url_parsed.query.split('&')
              [key, value] = dnsquery.split('=', 2)
              question[key] = value

            dns.lookup url_parsed.host, 4, (err, address, family)->
              if err
                log(app, false, "NS #{url_parsed.host} 解析失败: #{err}")
              else
                req = dns.Request({
                  question: question,
                  server: { address: address, port: url_parsed.port ? 53, type: 'udp' },
                  timeout: 2000,
                });
                req.on 'timeout', ()->
                  log(app, false, "DNS 请求超时")

                req.on 'message', (err, answer)->
                  if answer.answer.length
                    log(app, true, answer.answer[0].data)
                  else
                    log(app, false, "DNS 查询结果为空")

                req.send()
          else
            throw "unsupported procotol #{app.url}"

  , settings.interval

  http.createServer (req, res)->
    res.writeHead(200, {'Content-Type': 'text/plain'});
    res.end('nya');
  .listen(settings.port);