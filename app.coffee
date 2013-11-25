#标准库
path = require "path"
url = require 'url'
net = require 'net'
http = require 'http'

#三方库
express = require "express"
i18n = require "i18n"
moment = require 'moment-timezone'
request = require 'request'
nodemailer = require "nodemailer"
xmpp = require 'node-xmpp'
dns = require 'native-dns'
WebSocketClient = require("websocket").client
MongoClient = require('mongodb').MongoClient

#本地
settings = null
try
  settings = require './config.json'
catch
  settings = {
    interval: parseInt process.env.interval
    database: process.env.database
    port: parseInt process.env.PORT
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

smtp = nodemailer.createTransport "SMTP",settings.mail
xmpp_client = new xmpp.Client(settings.xmpp)
app = express()

i18n.configure
  locales:['en', 'zh'],
  directory: __dirname + '/locales'

# all environments
app.set "port", settings.port
app.set "views", path.join(__dirname, "views")
app.set "view engine", "hjs"
app.use express.favicon()
app.use express.logger("dev")
app.use express.json()
app.use express.urlencoded()
app.use express.methodOverride()
app.use i18n.init
app.use app.router
app.use express.static(path.join(__dirname, "public"), {maxAge:31557600000})

# development only
app.use express.errorHandler()  if "development" is app.get("env")

#TODO: 拆分文件
MongoClient.connect settings.database, (err, db)->
  throw err if err

  apps_collection = db.collection('apps')
  logs_collection = db.collection('logs')
  pages_collection = db.collection('pages')

  notice = (app, alive, message)->
    if app.contacts
      for contact in app.contacts
        url_parsed = url.parse contact
        console.log url_parsed
        switch url_parsed.protocol
          when 'mailto:'
            smtp.sendMail
              from: "萌卡监控 <zh99998@gmail.com>"
              to: contact.split(':',2)[1],
              subject: "#{app.name} #{if alive then '' else '不'}可用 (#{message})"
              text: "#{message}"
              html: "#{message}"
          when 'xmpp:'
            stanza = new xmpp.Element('message',{ to: contact.split(':',2)[1], type: 'chat' }).c('body').t(
              "#{app.name} #{if alive then '' else '不'}可用 (#{message})"
            )
            xmpp_client.send(stanza)

  #监控记录
  record = (app, alive, message)->
    message = message.toString()
    console.log "#{app.name} #{alive} #{message}"

    #存活，清空重试次数
    if alive and app.alive and app.retries
      apps_collection.update {_id:app._id}, {$set:{retries:0}}, (err)->
        throw err if err

    #存活状态变更
    if alive != app.alive
      date = new Date()

      if alive #上线
        console.log "#{app.name} up #{message}"

        notice(app, alive, message)

        apps_collection.update {_id:app._id}, {$set:{alive:alive, retries:0}}, (err)->
          throw err if err
        logs_collection.insert {app: app._id, alive: alive, message: message, created_at: date}, (err)->
          throw err if err

      else if app.retries >= 5 #下线
        console.log "#{app.name} down #{message}"

        notice(app, alive, message)

        apps_collection.update {_id:app._id}, {$set:{alive:alive}}, (err)->
          throw err if err
        logs_collection.insert {app: app._id, alive: alive, message: message, created_at: date}, (err)->
          throw err if err

      else #重试
        console.log "#{app.name} retry#{app.retries} #{message}"
        apps_collection.update {_id:app._id}, {$inc:{retries:1}}, (err)->
          throw err if err


  #监控逻辑
  setInterval ->
    apps_collection.find().each (err, app)->
      throw err if err
      if app
        url_parsed = url.parse app.url
        switch url_parsed.protocol
          when 'ws:', 'wss:'
            client = new WebSocketClient()
            client.on "connectFailed", (error) ->
              record(app, false, error)

            client.on "connect", (connection) ->
              connection.close()
              record(app, true, "WebSocket连接成功")

            client.connect app.url
          when 'http:', 'https:'
            request
              url: app.url
              timeout: 10000
              strictSSL: true
              headers: app.headers
            , (err, response, body)->
              if err #http失败
                record(app, false, err)
              else if response.statusCode >= 400 #http成功，但返回了4xx或5xx
                record(app, false, "HTTP #{response.statusCode} #{http.STATUS_CODES[response.statusCode]}")
              else #ok
                record(app, true, "HTTP #{response.statusCode} #{http.STATUS_CODES[response.statusCode]}")
          when 'xmpp:'
          #client = new xmpp.Client()
          #client.on 'error', (error)->
          #  console.error(error)
            null
          when 'tcp:'
            client = net.connect port:url_parsed.port, host:url_parsed.hostname, ->
              client.end()
              record(app, true, "TCP连接成功")
            client.on 'error', (error)->
              record(app, false, error)
          when 'dns:'
            question =
              name: url_parsed.pathname.slice(1)
            for dnsquery in url_parsed.query.split('&')
              [key, value] = dnsquery.split('=', 2)
              question[key] = value

            question = dns.Question question

            dns.lookup url_parsed.host, 4, (err, address, family)->
              if err
                record(app, false, "NS #{url_parsed.host} 解析失败: #{err}")
              else
                req = dns.Request({
                  question: question,
                  server: { address: address, port: url_parsed.port ? 53, type: 'udp' },
                  timeout: 10000,
                });

                req.on 'timeout', ()->
                  record(app, false, "DNS 请求超时")

                req.on 'message', (err, answer)->
                  if err
                    record(app, false, err)
                  else if answer.answer.length
                    ans = answer.answer[0]
                    record(app, true, ans.address ? ans.data ? JSON.stringify(ans))
                  else
                    record(app, false, "DNS 查询结果为空")

                req.send()
          else
            throw "unsupported procotol #{app.url}"

  , settings.interval

  #网站逻辑

  app.get "/", (req, res)->
    pages_collection.findOne domain: req.headers.host, (err, page)->
      throw err if err
      if page
        res.header('Cache-Control', 'no-cache, private, no-store, must-revalidate, max-stale=0, post-check=0, pre-check=0');
        apps = apps_collection.find(_id: {$in: page.apps}).toArray (err, apps)->
          throw err if err
          logs = logs_collection.find(app: {$in: page.apps}).sort({created_at: -1}).limit(10).toArray (err, logs)->
            throw err if err
            alive = true
            for app in apps
              if !app.alive
                alive = false
                break

            if alive #uptime
              uptime_humane = moment(logs[0]).tz("Asia/Shanghai").lang('zh-cn').fromNow(true); #TODO: 本地化时间显示
            else #downtime
              #logs.(app._id for app in apps when !app.alive)

            for log in logs
              log.created_at_humane = log.created_at.toString() #TODO: 本地化时间显示
              for app in apps
                if app._id.equals log.app
                  log.app = app
                  break
            res.render 'page', { page: page, apps: apps, logs: logs, alive: alive, uptime_humane: uptime_humane, locale: res.getLocale(), __:->res.__}
      else
        res.render 'index', { locale: res.getLocale(), __:->res.__ }
  app.get "/favicon.ico", (req, res)->
    pages_collection.findOne domain: req.headers.host, (err, page)->
      throw err if err
      if page and page.favicon
        res.redirect(301, page.favicon);
      else
        res.redirect(301, "https://my-card.in/favicon.ico");

  http.createServer(app).listen app.get("port"), ->
    console.log "Express server listening on port " + app.get("port")