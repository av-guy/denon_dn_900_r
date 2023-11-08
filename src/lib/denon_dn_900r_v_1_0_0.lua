local CommandPriorities = {
  LOW = 0,
  HIGH = 1
}

local QueueCommand = {
  New = function(self, object)
    object = object or {}

    if object.commandPriority == nil then
      object.commandPriority = CommandPriorities.LOW
    end

    if not object.CommandTimeout then
      object.CommandTimeout = 1.5
    end

    setmetatable(object, self)
    self.__index = self

    return object
  end,
}

local Denon900R = {
  New = function(self, object)
    object = object or {}
    setmetatable(object, self)
    self.__index = self

    self.__startCharacter = "@0"
    self.__cmdDelimiter = "\r"

    self.__NACK = "\x15"
    self.__ACK = "\x06"
    self.__busySignal = "@BDERBUSY"
    self.__successMatch = "(" .. self.__ACK .. ")" .. "\r"

    self.__matchTable = {
      ["Success"] = self.__successMatch,
      ["AdminLogin"] = "@0LI(%a*)\r",
      ["AlbumTitle"] = "@0al(.*)\r"
    }

    self.__parseTable = {
      [self.__matchTable["AdminLogin"]] = function(response) self:__AdminLoginUpdate(response) end,
    }

    self.__statusTable = {}
    self.__notifierTable = {}
    self.__pollCommands = {}

    return object
  end,

  __ACKAcknowledge = function(self, response)
    return string.find(response, self.__successMatch)
  end,

  __ACKMatch = function(self, response)
    local ack = self.__ACKAcknowledge(response)
    local nack = self.__NACKAcknowledge(response)

    if not ack or nack then
      error("AcceptableRatingsCommand: NACK received")
    end
  end,

  __AddCallback = function(self, commandName, callback)
    self.__notifierTable[commandName] = callback
  end,

  __AddToPollQueue = function(self, commandName, pollCommand)
    if self.__pollCommands[commandName] == nil then
      self.__pollCommands[commandName] = pollCommand()
    end
  end,

  __CallGenericCommand = function(self, commandName, methodName, ...)
    local cachedCommand = self.__commandCache[commandName]
    local args = { ... }

    local function createChangeCommand()
      return function()
        return self[methodName](self, table.unpack(args))
      end
    end

    if cachedCommand ~= nil then
      cachedCommand[commandName].changeCommand = createChangeCommand()
    else
      self.__commandCache[commandName] = QueueCommand:New({
        changeCommand = createChangeCommand(),
        responseCommand = function(response)
          self:__ACKMatch(response)
        end,
        commandPriority = CommandPriorities.HIGH
      })
    end

    self.__commandManager:EnqueueCommand(self.__commandCache[commandName])
  end,

  __ConcatTableKeys = function(_, valuesTable)
    local values = {}

    for key, _ in pairs(valuesTable) do
      table.insert(values, "`'" .. key .. "'`")
    end

    return table.concat(values, ", ")
  end,

  __ErrorHandler = function(self, errResponse)
    local match = string.find(errResponse, self.__busySignal)
    if match ~= nil then
      error("Unit is busy; cannot process request")
    end
  end,

  __NACKAcknowledge = function(self, response)
    return string.find(response, self.__NACK)
  end,

  __NotifyListeners = function(self, driverCmd, ...)
    local previousStatus = self.__statusTable[driverCmd]
    local args = { ... }
    local currentStatus = table.concat(args)

    if previousStatus ~= currentStatus then
      self.__statusTable[driverCmd] = currentStatus
      if self.__notifierTable[driverCmd] ~= nil then
        self.__notifierTable[driverCmd](...)
      end
    end
  end,

  __OnConnect = function(self, commInterface)
  end,

  __SubscribeToGroup = function(self, prefix, callback)
    if type(callback) ~= "function" then
      error(prefix .. "Subscribe: `callback` must be a function")
    else
      self:__AddCallback(prefix, callback)
      self:__AddToPollQueue(
        prefix,
        function()
          return self[prefix .. "Poll"](self)
        end
      )
    end
  end,

  __GeneratePollFunction = function(self, prefix)
    return function()
      return QueueCommand:New({
        pollCommand = function()
          return self["__" .. prefix .. "Poll"](self)
        end,
        responseCommand = function(response)
          return self["__" .. prefix .. "Update"](self, response)
        end
      })
    end
  end,

  GetStatus = function(self, commandName)
    return self.__statusTable[commandName]
  end,

  --
  -- Command Code for "AdminLoginCommand"
  --
  -- @param adminLoginPassword The admin login password.
  --
  -- @return A command string for performing admin login. The format of the command is:
  -- [startCharacter]?LI[adminLoginPassword][cmdDelimiter].
  --
  -- @raise Error If `adminLoginPassword` is nil or empty.
  --
  __AdminLoginCommand = function(self, adminLoginPassword)
    local cmdDelimiter = self.__cmdDelimiter
    local startCharacter = self.__startCharacter

    local staticPart = "?LI"

    if not adminLoginPassword or adminLoginPassword == "" then
      error("Error: `adminLoginPassword` cannot be nil or empty.")
    else
      local cmdString = startCharacter .. staticPart .. adminLoginPassword .. cmdDelimiter
      return cmdString
    end
  end,

  --
  -- Generates a command for performing admin login.
  --
  -- This method allows you to login as the administrator using the administrator
  -- credentials.
  --
  -- @param adminLoginPassword The admin login password.
  --
  AdminLoginCommand = function(self, adminLoginPassword)
    self:__CallGenericCommand(
      "AdminLogin",
      "__AdminLoginCommand",
      adminLoginPassword
    )
  end,

  --
  -- Private method for parsing and updating AdminLogin response
  --
  -- @param adminLoginResponse The response received from the communication module.
  --
  -- @return The updated admin login state value ("Success" or "Failed").
  --
  -- @raise Error If the response is invalid or does not match expected values.
  --
  __AdminLoginUpdate = function(self, adminLoginResponse)
    local adminLoginParse = self.__matchTable["AdminLogin"]

    local adminLoginValueTable = {
      ["OK"] = "Success",
      ["NG"] = "Failed"
    }

    local _, _, adminLoginStatus = string.find(adminLoginResponse, adminLoginParse)

    if adminLoginStatus and adminLoginValueTable[adminLoginStatus] then
      local convertedValue = adminLoginValueTable[adminLoginResponse]
      self:__NotifyListeners("AdminLogin", convertedValue)
      return convertedValue
    else
      error("Error: `__AdminLoginUpdate` failed: Invalid response received: " .. adminLoginResponse)
    end
  end,

  --
  -- Subscribe command for admin login state.
  --
  -- This method subscribes to updates of the admin login state and registers a callback function
  -- to be called when the admin login state changes.
  --
  -- @param callback A callback function to be called when the admin login state changes.
  --
  AdminLoginSubscribe = function(self, callback)
    self:__SubscribeToGroup("AdminLogin", callback)
  end,

  --
  -- Command Code for "AlbumTitlePoll"
  --
  -- @return A command string for polling the album title.
  --
  __AlbumTitlePoll = function(self)
    local cmdDelimiter = self.__cmdDelimiter
    local startCharacter = self.__startCharacter

    local staticPart = "?al"

    local pollString = startCharacter .. staticPart .. cmdDelimiter

    return pollString
  end,

  --
  -- Generates a command for polling the album title.
  --
  -- This method constructs a command string for polling the album title.
  --
  -- @param self The instance of the class or object invoking this method.
  --
  AlbumTitlePoll = function(self)
    self:__GeneratePollFunction("AlbumTitle")
  end,

  --
  -- Private method for parsing and updating AlbumTitle response.
  --
  -- @param albumTitleResponse The response received from the communication module.
  --
  -- @return The updated album title as a string (up to 255 characters long).
  --
  -- @raise Error If the response is invalid or exceeds 255 characters.
  --
  __AlbumTitleUpdate = function(self, albumTitleResponse)
    local albumTitleParse = self.__matchTable["AlbumTitle"]

    local _, _, albumTitle = string.find(albumTitleResponse, albumTitleParse)

    if albumTitle and #albumTitle <= 255 then
      self:__NotifyListeners("AlbumTitle", albumTitle)
      return albumTitle
    end

    error("Error: `__AlbumTitleUpdate` failed: Invalid response received or exceeds 255 characters.")
  end,

  --
  -- Subscribe command for album title state.
  --
  -- This method subscribes to updates of the album title state and registers a callback function
  -- to be called when the album title changes.
  --
  -- @param callback A callback function to be called when the album title changes.
  --
  AlbumTitleSubscribe = function(self, callback)
    self:__SubscribeToGroup("AlbumTitle", callback)
  end
}

return Denon900R
