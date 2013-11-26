@client_test = (apps, callback)->
  $.each apps, (index, app)->
    url = $.url app.url
    switch url.attr 'protocol'
      when 'http', 'https'
        $.get app.url, (data, textStatus, jqXHR)->
          callback(app, true, textStatus)
        .fail (error)->
          callback(app, false, error.statusText)
      when 'ws', 'wss'
        if(window.WebSocket)
          client = new WebSocket(app.url)

          returned = false
          client.onclose = (evt)->
            if !returned
              returned = true
              callback(app, false, evt.type)
          client.onerror = (evt)->
            if !returned
              returned = true
              callback(app, false, evt.type)

          if app.data
            client.onmessage = (evt)->
              if !returned
                returned = true
                callback(app, true, evt.type)

            setTimeout ->
              if !returned
                returned = true
                callback(app, true, 'timeout')
            , 10000

          else
            client.onopen = (evt)->
              returned = true
              callback(app, true, evt.type)
        else
          callback(app, null, "client not support websocket")
      else
        callback(app, null, "unsupported protocol")