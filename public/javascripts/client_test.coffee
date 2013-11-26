@client_test = (apps, callback)->
  $.each apps, (index, app)->
    url = $.url app.url
    switch url.attr 'protocol'
      when 'http', 'https'
        $.get app.url, (data, textStatus, jqXHR)->
          console.log app.url, data, textStatus, jqXHR
          callback(app, true, textStatus)
        .fail (jqXHR, textStatus, errorThrown)->
            console.log app.url, jqXHR, textStatus, errorThrown
            if(errorThrown == 'No Transport')
              callback(app, null, errorThrown)
            else
              callback(app, false, errorThrown)
      when 'ws', 'wss'
        if(window.WebSocket)
          client = new WebSocket(app.url)

          alive = null
          client.onopen = (evt)->
            console.log app.url, 'open', evt
            if !app.data
              alive = true
              callback(app, alive, evt.type)
              client.close() if !app.connection

          client.onmessage = (evt)->
            console.log app.url, 'message', evt
            if !alive?
              alive = true
              callback(app, alive, evt.type)

          client.onclose = (evt)->
            console.log app.url, 'close', evt
            if app.connection or !alive?
              alive = false
              callback(app, alive, evt.type)

          client.onerror = (evt)->
            console.log app.url, 'error', evt
            if app.connection or !alive?
              alive = false
              callback(app, alive, evt.type)

          setTimeout ->
            console.log app.url, 'timeout'
            if !alive?
              alive = false
              callback(app, alive, 'timeout')
              client.close()

          , 10000

        else
          callback(app, null, "client not support websocket")
      else
        callback(app, null, "unsupported protocol")