// Generated by CoffeeScript 1.6.3
(function() {
  var MongoClient, WebSocketClient, dns, http, net, nodemailer, request, settings, smtp, url, xmpp, xmpp_client;

  settings = null;

  try {
    settings = require('./config.json');
  } catch (_error) {
    settings = {
      interval: parseInt(process.env.inteval),
      database: process.env.database,
      port: process.env.port,
      mail: {
        service: process.env.mail_service,
        auth: {
          user: process.env.mail_auth_user,
          pass: process.env.mail_auth_pass
        }
      },
      xmpp: {
        jid: process.env.xmpp_jid,
        password: process.env.xmpp_password
      }
    };
  }

  console.log(settings);

  url = require('url');

  net = require('net');

  http = require('http');

  request = require('request');

  nodemailer = require("nodemailer");

  xmpp = require('node-xmpp');

  dns = require('native-dns');

  WebSocketClient = require("websocket").client;

  MongoClient = require('mongodb').MongoClient;

  smtp = nodemailer.createTransport("SMTP", settings.mail);

  xmpp_client = new xmpp.Client(settings.xmpp);

  MongoClient.connect(settings.database, function(err, db) {
    var apps_collection, log, logs_collection;
    if (err) {
      throw err;
    }
    apps_collection = db.collection('apps');
    logs_collection = db.collection('logs');
    log = function(app, alive, message) {
      var date, stanza;
      console.log("" + app.name + " " + alive + " " + message);
      if (alive !== app.alive) {
        date = new Date();
        logs_collection.insert({
          app: app._id,
          alive: alive,
          message: message,
          created_at: date
        }, function(err) {
          if (err) {
            throw err;
          }
        });
        if (alive) {
          console.log("" + app.name + " up " + message);
          smtp.sendMail({
            from: "萌卡监控 <zh99998@gmail.com>",
            to: "zh99998@gmail.com",
            subject: "萌卡监控 - " + app.name + " 恢复可用 (" + message + ")",
            text: "" + message,
            html: "" + message
          });
          stanza = new xmpp.Element('message', {
            to: 'zh99998@gmail.com',
            type: 'chat'
          }).c('body').t("萌卡监控 - " + app.name + " 恢复可用 (" + message + ")");
          xmpp_client.send(stanza);
          return apps_collection.update({
            _id: app._id
          }, {
            $set: {
              alive: alive,
              retries: 0
            }
          }, function(err) {
            if (err) {
              throw err;
            }
          });
        } else if (app.retries >= 5) {
          console.log("" + app.name + " down " + message);
          smtp.sendMail({
            from: "萌卡监控 <zh99998@gmail.com>",
            to: "zh99998@gmail.com",
            subject: "萌卡监控 - " + app.name + " 不可用 (" + message + ")",
            text: "" + message,
            html: "" + message
          });
          stanza = new xmpp.Element('message', {
            to: 'zh99998@gmail.com',
            type: 'chat'
          }).c('body').t("萌卡监控 - " + app.name + " 不可用 (" + message + ")");
          xmpp_client.send(stanza);
          return apps_collection.update({
            _id: app._id
          }, {
            $set: {
              alive: alive
            }
          }, function(err) {
            if (err) {
              throw err;
            }
          });
        } else {
          console.log("" + app.name + " retry" + app.retries + " " + message);
          return apps_collection.update({
            _id: app._id
          }, {
            $inc: {
              retries: 1
            }
          }, function(err) {
            if (err) {
              throw err;
            }
          });
        }
      }
    };
    setInterval(function() {
      return apps_collection.find().toArray(function(err, apps) {
        return apps.forEach(function(app) {
          var client, dnsquery, key, question, url_parsed, value, _i, _len, _ref, _ref1;
          url_parsed = url.parse(app.url);
          switch (url_parsed.protocol) {
            case 'ws:':
            case 'wss:':
              client = new WebSocketClient();
              client.on("connectFailed", function(error) {
                return log(app, false, error);
              });
              client.on("connect", function(connection) {
                this.close();
                return log(app, true, "WebSocket连接成功");
              });
              return client.connect(app.url);
            case 'http:':
            case 'https:':
              return request({
                url: app.url,
                timeout: 10000,
                strictSSL: true
              }, function(err, response, body) {
                if (err) {
                  return log(app, false, err);
                } else if (response.statusCode >= 400) {
                  return log(app, false, "HTTP " + response.statusCode + " " + http.STATUS_CODES[response.statusCode]);
                } else {
                  return log(app, true, "HTTP " + response.statusCode + " " + http.STATUS_CODES[response.statusCode]);
                }
              });
            case 'xmpp:':
              return null;
            case 'tcp:':
              client = net.connect({
                port: url_parsed.port,
                host: url_parsed.hostname
              }, function() {
                client.end();
                return log(app, true, "TCP连接成功");
              });
              return client.on('error', function(error) {
                return log(app, false, "error");
              });
            case 'dns:':
              question = dns.Question({
                name: url_parsed.pathname.slice(1)
              });
              _ref = url_parsed.query.split('&');
              for (_i = 0, _len = _ref.length; _i < _len; _i++) {
                dnsquery = _ref[_i];
                _ref1 = dnsquery.split('=', 2), key = _ref1[0], value = _ref1[1];
                question[key] = value;
              }
              return dns.lookup(url_parsed.host, 4, function(err, address, family) {
                var req, _ref2;
                if (err) {
                  return log(app, false, "NS " + url_parsed.host + " 解析失败: " + err);
                } else {
                  req = dns.Request({
                    question: question,
                    server: {
                      address: address,
                      port: (_ref2 = url_parsed.port) != null ? _ref2 : 53,
                      type: 'udp'
                    },
                    timeout: 2000
                  });
                  req.on('timeout', function() {
                    return log(app, false, "DNS 请求超时");
                  });
                  req.on('message', function(err, answer) {
                    if (answer.answer.length) {
                      return log(app, true, answer.answer[0].data);
                    } else {
                      return log(app, false, "DNS 查询结果为空");
                    }
                  });
                  return req.send();
                }
              });
            default:
              throw "unsupported procotol " + app.url;
          }
        });
      });
    }, settings.interval);
    return http.createServer(function(req, res) {
      res.writeHead(200, {
        'Content-Type': 'text/plain'
      });
      return res.end('nya');
    }).listen(settings.port);
  });

}).call(this);

/*
//@ sourceMappingURL=mycard-monitor.map
*/
