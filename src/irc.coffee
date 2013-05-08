# This is a fork of @nandub's hubot-irc that authenticates users via /whois 330s.
# It has only been tested on freenode.

# Hubot dependencies
{Robot, Adapter, TextMessage, EnterMessage, LeaveMessage, Response} = require 'hubot'

# Irc library
Irc = require 'irc'

class IrcBot extends Adapter
  constructor: ->
    super
    @knownUsers = {}

  send: (envelope, strings...) ->
    # Use @notice if SEND_NOTICE_MODE is set
    return @notice envelope, strings if process.env.HUBOT_IRC_SEND_NOTICE_MODE?

    target = @_getTargetFromEnvelope envelope

    unless target
      return console.log "ERROR: Not sure who to send to. envelope=", envelope

    for str in strings
      @bot.say target, str

  notice: (envelope, strings...) ->
    target = @_getTargetFromEnvelope envelope

    unless target
      return console.log "Notice: no target found", envelope

    # Flatten out strings from send
    flattened = []
    for str in strings
      if Array.isArray str
        flattened = flattened.concat str
      else
        flattened.push str

    for str in flattened
      if not str?
        continue

      @bot.notice target, str

  reply: (envelope, strings...) ->
    for str in strings
      @send envelope.user, "#{envelope.user.nick}: #{str}"

  join: (channel) ->
    @bot.join channel, () =>
      console.log('joined %s', channel)

      @receive new EnterMessage({})

  part: (channel) ->
    @bot.part channel, () =>
      console.log('left %s', channel)

      @receive new LeaveMessage({})

  getUser: (channel, from, callback = ->) ->
    user = @knownUsers[""+channel]?[""+from]
    if user?
      if channel.match(/^[&#]/)
        user.room = channel
      else
        user.room = null
      user.nick = from # In case they're logged in more than once
      callback user
      return
    @ircClient.whois from, (details) =>
      if details.account?.length
        # They're authenticated with NickServ
        user = @robot.brain.userForId details.account
        user.name = details.account
        user.authenticated = true
      else
        # They're not authenticated
        id = "---"+from
        user = @robot.brain.userForId id
        user.name = from
        user.authenticated = false
      user.nick = from
      user.channels ?= []

      if channel.match(/^[&#]/)
        user.room = channel
        if user.channels.indexOf(channel) is -1
          user.channels.push channel
          # XXX: Remove from channels on part/quit/kill/etc
      else
        user.room = null

      @knownUsers[""+channel] ?= {}
      @knownUsers[""+channel][""+from] = user

      callback user

  kick: (channel, client, message) ->
    @bot.emit 'raw',
      command: 'KICK'
      nick: process.env.HUBOT_IRC_NICK
      args: [ channel, client, message ]

  command: (command, strings...) ->
    @bot.send command, strings...

  checkCanStart: ->
    if not process.env.HUBOT_IRC_NICK and not @robot.name
      throw new Error("HUBOT_IRC_NICK is not defined; try: export HUBOT_IRC_NICK='mybot'")
    else if not process.env.HUBOT_IRC_ROOMS
      throw new Error("HUBOT_IRC_ROOMS is not defined; try: export HUBOT_IRC_ROOMS='#myroom'")
    else if not process.env.HUBOT_IRC_SERVER
      throw new Error("HUBOT_IRC_SERVER is not defined: try: export HUBOT_IRC_SERVER='irc.myserver.com'")

  run: ->
    do @checkCanStart

    options =
      nick:     process.env.HUBOT_IRC_NICK or @robot.name
      realName: process.env.HUBOT_IRC_REALNAME
      port:     process.env.HUBOT_IRC_PORT
      rooms:    process.env.HUBOT_IRC_ROOMS.split(",")
      server:   process.env.HUBOT_IRC_SERVER
      password: process.env.HUBOT_IRC_PASSWORD
      nickpass: process.env.HUBOT_IRC_NICKSERV_PASSWORD
      nickusername: process.env.HUBOT_IRC_NICKSERV_USERNAME
      connectCommand: process.env.HUBOT_IRC_CONNECT_COMMAND
      fakessl:  process.env.HUBOT_IRC_SERVER_FAKE_SSL?
      certExpired: process.env.HUBOT_IRC_SERVER_CERT_EXPIRED?
      unflood:  process.env.HUBOT_IRC_UNFLOOD?
      debug:    process.env.HUBOT_IRC_DEBUG?
      usessl:   process.env.HUBOT_IRC_USESSL?
      userName: process.env.HUBOT_IRC_USERNAME

    client_options =
      userName: options.userName
      realName: options.realName
      password: options.password
      debug: options.debug
      port: options.port
      stripColors: true
      secure: options.usessl
      selfSigned: options.fakessl
      certExpired: options.certExpired
      floodProtection: options.unflood

    client_options['channels'] = options.rooms unless options.nickpass

    @robot.name = options.nick
    bot = @ircClient = new Irc.Client options.server, options.nick, client_options

    next_id = 1
    user_id = {}

    if options.nickpass?
      identify_args = ""

      if options.nickusername?
        identify_args += "#{options.nickusername} "

      identify_args += "#{options.nickpass}"

      bot.addListener 'notice', (from, to, text) =>
        if from is 'NickServ' and text.toLowerCase().indexOf('identify') isnt -1
          bot.say 'NickServ', "identify #{identify_args}"
        else if options.nickpass and from is 'NickServ' and
                (text.indexOf('Password accepted') isnt -1 or
                 text.indexOf('identified') isnt -1)
          for room in options.rooms
            @join room

    if options.connectCommand?
      bot.addListener 'registered', (message) =>
        # The 'registered' event is fired when you are connected to the server
        strings = options.connectCommand.split " "
        @command strings.shift(), strings...

    bot.addListener 'names', (channel, nicks) =>
      for nick of nicks
        @getUser channel, nick, null

    bot.addListener 'message', (from, to, message) =>
      if options.nick.toLowerCase() == to.toLowerCase()
        # this is a private message, let the 'pm' listener handle it
        return

      console.log "From #{from} to #{to}: #{message}"

      @getUser to, from, (user) =>
        if user.room
          console.log "#{to} <#{from}> #{message}"
        else
          unless message.indexOf(to) == 0
            message = "#{to}: #{message}"
          console.log "msg <#{from}> #{message}"

        @receive new TextMessage(user, message)

    bot.addListener 'error', (message) =>
      console.error('ERROR: %s: %s', message.command, message.args.join(' '))

    bot.addListener 'pm', (nick, message) =>
      console.log('Got private message from %s: %s', nick, message)

      if process.env.HUBOT_IRC_PRIVATE
        return

      nameLength = options.nick.length
      to = options.nick
      if message.slice(0, nameLength).toLowerCase() != options.nick.toLowerCase()
        message = "#{to} #{message}"

      @getUser to, nick, (user) =>
        @receive new TextMessage(user, message)

    bot.addListener 'join', (channel, who) =>
      console.log('%s has joined %s', who, channel)
      @getUser channel, who, (user) =>
        @receive new EnterMessage(user)

    bot.addListener 'part', (channel, who, reason) =>
      console.log('%s has left %s: %s', who, channel, reason)
      delete @knownUsers[channel]?[who]
      @getUser '', who, (user) =>
        @receive new LeaveMessage(user)

    bot.addListener 'quit', (who, reason, channels) =>
      for channel in channels ? []
        delete @knownUsers[channel]?[who]

    bot.addListener 'nick', (oldNick, newNick, channels, message) =>
      for channel in channels ? []
        delete @knownUsers[channel]?[oldNick]

    bot.addListener 'kill', (who, reason, channels) =>
      for channel in channels ? []
        delete @knownUsers[channel]?[who]

    bot.addListener 'kick', (channel, who, _by, reason) =>
      delete @knownUsers[channel]?[who]
      console.log('%s was kicked from %s by %s: %s', who, channel, _by, reason)

    bot.addListener 'invite', (channel, from) =>
      console.log('%s invite you to join %s', from, channel)

      if not process.env.HUBOT_IRC_PRIVATE
        bot.join channel

    bot.addListener 'nick', (channel, who, _by, reason) =>
      delete @knownUsers[channel]?[who]

    bot.addListener '+mode', (channel, _by, mode, argument, message) =>
      delete @knownUsers[channel]?[argument]

    bot.addListener '-mode', (channel, _by, mode, argument, message) =>
      delete @knownUsers[channel]?[argument]

    @bot = bot

    @emit "connected"

  _getTargetFromEnvelope: (envelope) ->
    user = null
    room = null
    target = null

    # as of hubot 2.4.2, the first param to send() is an object with 'user'
    # and 'room' data inside. detect the old style here.
    if envelope.reply_to
      user = envelope
    else
      # expand envelope
      user = envelope.user ? envelope
      room = envelope.room
      if user? and not room?
        return user.nick

    if user
      # most common case - we're replying to a user in a room
      if user.room
        target = user.room
      # reply directly
      else if user.nick
        target = user.nick
      # replying to pm
      else if user.reply_to
        target = user.reply_to
      # allows user to be an id string
      else if user.search?(/@/) != -1
        target = user
    else if room
      # this will happen if someone uses robot.messageRoom(jid, ...)
      target = room

    target

exports.use = (robot) ->
  new IrcBot robot
