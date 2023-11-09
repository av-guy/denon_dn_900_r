local CommandPriorities = {
  LOW = 0,
  HIGH = 1
}

local DaysOfWeek = {
  MONDAY = "Monday",
  TUESDAY = "Tuesday",
  WEDNESDAY = "Wednesday",
  THURSDAY = "Thursday",
  FRIDAY = "Friday",
  SATURDAY = "Saturday",
  SUNDAY = "Sunday"
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

local function tableToString(tbl)
  local result = "{"
  for k, v in pairs(tbl) do
    -- Check the key type (ignore any numerical keys - assume its an array)
    if type(k) == "string" then
      result = result .. "[\"" .. k .. "\"]" .. "="
    end

    -- Check the value type
    if type(v) == "table" then
      result = result .. tableToString(v)
    elseif type(v) == "boolean" then
      result = result .. tostring(v)
    else
      result = result .. "\"" .. v .. "\""
    end
    result = result .. ","
  end

  -- Remove leading commas from the result
  if result ~= "" then
    result = result:sub(1, result:len() - 1)
  end

  return result .. "}"
end

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
      ["AlbumTitle"] = "@0al(.*)\r",
      ["ArchiveMode"] = "@0AR(.*)\r",
      ["ArchiveClearSetting"] = "@0CA(%d*)\r",
      ["ArchiveTimerSetting"] = "@0asDW([%a_]*)(%d*)\r",
      ["AutoDeletion"] = "@0AD(.*)\r",
      ["RecordingVolume"] = "@0RV(%d%d)(%d%d)\r"
    }

    self.__parseTable = {
      [self.__matchTable["AdminLogin"]] = function(response) self:__AdminLoginUpdate(response) end,
      [self.__matchTable["AlbumTitle"]] = function(response) self:__AlbumTitleUpdate(response) end,
      [self.__matchTable["ArchiveMode"]] = function(response) self:__ArchiveModeUpdate(response) end,
      [self.__matchTable["ArchiveClearSetting"]] = function(response) self:__ArchiveClearSettingUpdate(response) end,
      [self.__matchTable["ArchiveTimerSetting"]] = function(response) self:__ArchiveTimerUpdate(response) end,
      [self.__matchTable["AutoDeletion"]] = function(response) self:__AutoDeletionUpdate(response) end
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

  __HasValue = function(_, valueToFind, listValues)
    for _, value in pairs(listValues) do
      if value == valueToFind then
        return true
      end
    end

    return false
  end,

  __NACKAcknowledge = function(self, response)
    return string.find(response, self.__NACK)
  end,

  __NotifyListeners = function(self, driverCmd, ...)
    local previousStatus = self.__statusTable[driverCmd]
    local args = { ... }
    local currentStatus = tableToString(args)

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
  -- This method constructs a queue command object and stages it for polling
  -- the album title.
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
  end,

  ---
  -- Command Code for "AutoDeletionCommand"
  --
  -- @param autoDeletionValue The desired auto deletion value, an integer between 1 and 24 representing hours.
  --
  -- @return A command string that can be sent to set the auto deletion value. The format of the command
  -- is: [startCharacter]AD[autoDeletionCode][cmdDelimiter].
  --
  -- @raise Error If `autoDeletionValue` is not within the valid range.
  --
  __AutoDeletionCommand = function(self, autoDeletionValue)
    local cmdDelimiter = self.__cmdDelimiter
    local startCharacter = self.__startCharacter

    local staticPart = "AD"

    if autoDeletionValue == "Off" then
      autoDeletionValue = "OF"
    elseif type(autoDeletionValue) == "number" and autoDeletionValue >= 1 and autoDeletionValue <= 24 then
      autoDeletionValue = string.format("%02d", autoDeletionValue)
    else
      error("Error: `autoDeletionValue` must be an integer between 1 and 24 or 'Off'")
    end

    local cmdString = startCharacter .. staticPart .. autoDeletionValue .. cmdDelimiter
    return cmdString
  end,

  ---
  -- Generates a command for setting the auto deletion value.
  -- Sets the DN-900R to automatically delete archived files when the available memory on
  -- the current media source becomes limited to a specified amount of record time.
  --
  -- @param autoDeletionValue The desired auto deletion value, an integer between 1 and 24 representing hours.
  --
  AutoDeletionCommand = function(self, autoDeletionValue)
    self:__CallGenericCommand(
      "AutoDeletion",
      "__AutoDeletionCommand",
      autoDeletionValue
    )
  end,

  ---
  -- Command Code for "AutoDeletionPoll"
  -- This method constructs a queue command object and stages it for polling
  -- the auto deletion value.
  --
  -- @return A command string for polling the auto deletion value.
  --
  __AutoDeletionPoll = function(self)
    local cmdDelimiter = self.__cmdDelimiter
    local startCharacter = self.__startCharacter

    local staticPart = "?AD"

    local pollString = startCharacter .. staticPart .. cmdDelimiter

    return pollString
  end,

  ---
  -- Generates a command for polling the auto deletion value.
  --
  --
  AutoDeletionPoll = function(self)
    self:__GeneratePollFunction("AutoDeletion")
  end,

  ---
  -- Private method for parsing and updating auto deletion response
  --
  -- @param autoDeletionResponse The response received from the communication module, containing
  -- information about the auto deletion value (e.g., "01").
  --
  -- @return The updated auto deletion value as an integer or "Off".
  --
  -- @raise Error If the response is invalid or cannot be converted to an integer or the value is not
  -- "Off".
  --
  __AutoDeletionUpdate = function(self, autoDeletionResponse)
    local _, _, autoDeletionMatch = string.find(
      autoDeletionResponse,
      self.__matchTable["AutoDeletion"]
    )

    local autoDeletionValue

    if autoDeletionMatch ~= nil then
      if autoDeletionMatch == "OF" then
        autoDeletionValue = "Off"
      else
        autoDeletionValue = tonumber(autoDeletionMatch)
      end

      if autoDeletionValue ~= nil then
        self:__NotifyListeners("AutoDeletion", autoDeletionValue)
        return autoDeletionValue
      else
        error("Error: `__AutoDeletionUpdate` failed: Unable to convert response to an integer: " .. autoDeletionResponse)
      end
    else
      error("Error: `__AutoDeletionUpdate` failed: No match found for " .. autoDeletionResponse)
    end
  end,

  ---
  -- Subscribe command for auto deletion value.
  --
  -- This method subscribes to updates of the auto deletion value and registers a callback function
  -- to be called when the auto deletion value changes.
  --
  -- @param callback A callback function to be called when the auto deletion value changes.
  --
  AutoDeletionSubscribe = function(self, callback)
    self:__SubscribeToGroup("AutoDeletion", callback)
  end,

  --
  -- Command Code for "ArchiveModeSetCommand"
  --
  -- @param archiveModeType The desired archive mode type. Should be one of the following:
  -- "Auto", "Scheduled", or "Off".
  --
  -- @return A command string for setting the archive mode. The format of the command is:
  -- [startCharacter]AR[archiveModeType][cmdDelimiter].
  --
  -- @raise Error If `archiveModeType` is not one of the valid mode types.
  --
  __ArchiveModeSetCommand = function(self, archiveModeType)
    local cmdDelimiter = self.__cmdDelimiter
    local startCharacter = self.__startCharacter

    local archiveModeTypeTable = {
      ["Auto"] = "AT",
      ["Scheduled"] = "SC",
      ["Off"] = "01"
    }

    local staticPart = "AR"

    if archiveModeTypeTable[archiveModeType] == nil then
      local validValues = self:__ConcatTableKeys(archiveModeTypeTable)
      local invalidValue = "`archiveModeType` (" .. archiveModeType .. ")"
      error(invalidValue .. " is not a valid value; should be " .. validValues)
    else
      local cmdString = startCharacter .. staticPart .. archiveModeTypeTable[archiveModeType] .. cmdDelimiter
      return cmdString
    end
  end,

  --
  -- Generates a command for setting the archive mode.
  --
  -- Sets whether/how the DN-900R will archive recorded files, where the value
  -- provided determines the behavior.
  --
  -- @param archiveModeType The desired archive mode type. Should be one of the following:
  --  * "Auto" - Recorded files will be automatically archived as soon as recording has finished.
  --  * "Scheduled" - Recorded files will be archived according to a set schedule.
  --  * "Off" - No archiving will be performed.
  --
  -- This method constructs a command string for setting the archive mode.
  --
  ArchiveModeSetCommand = function(self, archiveModeType)
    self:__CallGenericCommand(
      "ArchiveModeSet",
      "__ArchiveModeSetCommand",
      archiveModeType
    )
  end,

  --
  -- Command Code for "ArchiveModePoll"
  --
  -- @return A command string for polling the archive mode.
  --
  __ArchiveModePoll = function(self)
    local cmdDelimiter = self.__cmdDelimiter
    local startCharacter = self.__startCharacter

    local staticPart = "?AR"

    local pollString = startCharacter .. staticPart .. cmdDelimiter

    return pollString
  end,

  --
  -- Generates a command for polling the archive mode.
  --
  -- This method constructs a queue command object and stages it for polling
  -- the archive mode.
  --
  ArchiveModePoll = function(self)
    self:__GeneratePollFunction("ArchiveMode")
  end,

  --
  -- Private method for parsing and updating ArchiveMode response.
  --
  -- @param archiveModeResponse The response received from the communication module.
  --
  -- @return The updated archive mode as a string ("Auto", "Scheduled", or "Off").
  --
  -- @raise Error If the response is invalid or does not match expected values.
  --
  __ArchiveModeUpdate = function(self, archiveModeResponse)
    local archiveModeValueTable = {
      ["AT"] = "Auto",
      ["SC"] = "Scheduled",
      ["01"] = "Off"
    }

    local _, _, archiveModeStatus = string.find(
      archiveModeResponse,
      self.__matchTable["ArchiveMode"]
    )

    if archiveModeStatus and archiveModeValueTable[archiveModeStatus] then
      local convertedValue = archiveModeValueTable[archiveModeStatus]
      self:__NotifyListeners("ArchiveMode", convertedValue)
      return convertedValue
    else
      error("Error: `__ArchiveModeUpdate` failed: Invalid response received: " .. archiveModeResponse)
    end
  end,

  --
  -- Subscribe command for archive mode state.
  --
  -- This method subscribes to updates of the archive mode state and registers a callback function
  -- to be called when the archive mode changes.
  --
  -- @param callback A callback function to be called when the archive mode changes.
  --
  ArchiveModeSubscribe = function(self, callback)
    self:__SubscribeToGroup("ArchiveMode", callback)
  end,

  --
  -- Command Code for "ArchiveClearSettingCommand"
  --
  -- @param clearSettingValue The desired clear setting value. Should be one of the following:
  -- "On" or "Off".
  --
  -- @return A command string for setting the archive clear setting. The format of the command is:
  -- [startCharacter]CA[clearSettingValue][cmdDelimiter].
  --
  -- @raise Error If `clearSettingValue` is not one of the valid values.
  --
  __ArchiveClearSettingCommand = function(self, clearSettingValue)
    local cmdDelimiter = self.__cmdDelimiter
    local startCharacter = self.__startCharacter

    local clearSettingValueTable = {
      ["On"] = "00",
      ["Off"] = "01"
    }

    local staticPart = "CA"

    if clearSettingValueTable[clearSettingValue] == nil then
      local validValues = self:__ConcatTableKeys(clearSettingValueTable)
      local invalidValue = "`clearSettingValue` (" .. clearSettingValue .. ")"
      error(invalidValue .. " is not a valid value; should be " .. validValues)
    else
      local cmdString = startCharacter .. staticPart .. clearSettingValueTable[clearSettingValue] .. cmdDelimiter
      return cmdString
    end
  end,

  --
  -- Generates a command for setting the archive clear setting.
  -- Sets whether the DN-900R automatically deletes recorded files after they are archived.
  --
  -- @param clearSettingValue The desired clear setting value. Should be one of the following:
  -- "On" or "Off".
  --
  -- This method constructs a command string for setting the archive clear setting.
  --
  ArchiveClearSettingCommand = function(self, clearSettingValue)
    self:__CallGenericCommand(
      "ArchiveClearSetting",
      "__ArchiveClearSettingCommand",
      clearSettingValue
    )
  end,

  --
  -- Command Code for "ArchiveClearSettingPoll"
  --
  -- @return A command string for polling the archive clear setting.
  --
  __ArchiveClearSettingPoll = function(self)
    local cmdDelimiter = self.__cmdDelimiter
    local startCharacter = self.__startCharacter

    local staticPart = "?CA"

    local pollString = startCharacter .. staticPart .. cmdDelimiter

    return pollString
  end,

  --
  -- Generates a command for polling the archive clear setting.
  -- This method constructs a queue command object and stages it for polling
  -- the archive clear setting mode.
  --
  ArchiveClearSettingPoll = function(self)
    self:__GeneratePollFunction("ArchiveClearSetting")
  end,

  --
  -- Private method for parsing and updating ArchiveClearSetting response.
  --
  -- @param recordClearSettingResponse The response received from the communication module.
  --
  -- @return The updated clear setting value ("On" or "Off").
  --
  -- @raise Error If the response is invalid or does not match expected values.
  --
  __ArchiveClearSettingUpdate = function(self, recordClearSettingResponse)
    local clearSettingValueTable = {
      ["00"] = "On",
      ["01"] = "Off"
    }

    local _, _, clearSettingMatch = string.find(
      recordClearSettingResponse,
      self.__matchTable["ArchiveClearSetting"]
    )

    if clearSettingMatch and clearSettingValueTable[clearSettingMatch] then
      local convertedValue = clearSettingValueTable[recordClearSettingResponse]
      self:__NotifyListeners("ArchiveClearSetting", convertedValue)
      return convertedValue
    else
      error("Error: `__ArchiveClearSettingUpdate` failed: Invalid response received: " .. recordClearSettingResponse)
    end
  end,

  --
  -- Subscribe command for archive clear setting state.
  --
  -- This method subscribes to updates of the archive clear setting state and registers a callback function
  -- to be called when the archive clear setting changes.
  --
  -- @param callback A callback function to be called when the archive clear setting changes.
  --
  ArchiveClearSettingSubscribe = function(self, callback)
    self:__SubscribeToGroup("ArchiveClearSetting", callback)
  end,

  --
  -- Command Code for "ArchiveTimerSettingPoll"
  --
  -- @return A command string for polling the archive timer setting.
  --
  __ArchiveTimerSettingPoll = function(self)
    local cmdDelimiter = self.__cmdDelimiter
    local startCharacter = self.__startCharacter

    local staticPart = "?Sh"

    local pollString = startCharacter .. staticPart .. cmdDelimiter

    return pollString
  end,

  --
  -- Generates a command for polling the archive timer setting.
  --
  -- This method constructs a queue command object and stages it for polling
  -- the archive mode.
  --
  ArchiveTimerSettingPoll = function(self)
    self:__GeneratePollFunction("ArchiveTimerSetting")
  end,

  --
  -- Private method for parsing and updating ArchiveTimerSetting response.
  --
  -- @param archiveTimerSettingResponse The response received from the device.
  --
  -- @return Two values: daysOfWeek (a list of selected days), startTime (formatted as "hh:mm"),
  --
  -- @raise Error If the response is invalid or does not match expected values.
  --
  __ArchiveTimerSettingUpdate = function(self, archiveTimerSettingResponse)
    local _, _, daysOfWeek, startTime = string.find(
      archiveTimerSettingResponse,
      self.__matchTable["ArchiveTimerSetting"]
    )

    if not daysOfWeek or not startTime then
      error("Error: `__ArchiveTimerSettingUpdate` failed: Invalid response received: " .. archiveTimerSettingResponse)
    end

    local daysOfWeekList = {}

    local daysOfWeekMap = {
      "Sunday",
      "Monday",
      "Tuesday",
      "Wednesday",
      "Thursday",
      "Friday",
      "Saturday"
    }

    for i = 1, #daysOfWeek do
      local day = string.sub(daysOfWeek, i, i)
      if day ~= "_" then
        table.insert(daysOfWeekList, daysOfWeekMap[i])
      end
    end

    local convertedStartTime = string.sub(startTime, 1, 2) .. ":" .. string.sub(startTime, 3, 4)
    self:__NotifyListeners("ArchiveTimerSetting", daysOfWeekList, convertedStartTime)

    return { daysOfWeekList, convertedStartTime }
  end,

  --
  -- Subscribe command for archive timer setting state.
  --
  -- This method subscribes to updates of the archive timer setting state and registers a callback function
  -- to be called when the timer setting changes.
  --
  -- @param callback A callback function to be called when the archive timer setting changes.
  --
  ArchiveTimerSettingSubscribe = function(self, callback)
    self:__SubscribeToGroup("ArchiveTimerSetting", callback)
  end,

  ---
  -- Command Code for "RecordingInputAnalogLevelCommand"
  --
  -- @param inputAdjustValue The desired input adjust value, a decimal number between -2.0 and 2.0.
  --
  -- @param channelValue The desired channel value, should be one of "Left" or "Right".
  --
  -- @return A command string that can be sent to set the recording input analog level. The format of the command
  -- is: [startCharacter]lt[inputAdjustCode][channelCode][cmdDelimiter].
  --
  -- @raise Error If `inputAdjustValue` is not within the valid range or `channelValue` is not valid.
  --
  __RecordingInputAnalogLevelCommand = function(self, inputAdjustValue, channelValue)
    local cmdDelimiter = self.__cmdDelimiter
    local startCharacter = self.__startCharacter

    local staticPart = "lt"


    local channelCode

    local channelCodeValues = {
      ["Left"] = "L",
      ["Right"] = "R"
    }

    channelCode = channelCodeValues[channelValue]

    if channelCode == nil then
      error("`channelValue` must be one of 'Left' or 'Right'.")
    end

    if type(inputAdjustValue) == "number" and inputAdjustValue >= -2.0 and inputAdjustValue <= 2.0 then
      local inputAdjustCode = string.format("%+d", inputAdjustValue * 10)
      local cmdString = startCharacter .. staticPart .. channelCode .. inputAdjustCode .. cmdDelimiter
      return cmdString
    else
      error("`inputAdjustValue` must be a decimal number between -2.0 and 2.0.")
    end
  end,

  ---
  -- Generates a command for setting the recording input analog level.
  -- Adjusts the analog input volume level for either the left or right channel.
  --
  -- @param inputAdjustValue The desired input adjust value, a decimal number between -2.0 and 2.0.
  --
  -- @param channelValue The desired channel value, should be one of "Left" or "Right".
  --
  RecordingInputAnalogLevelCommand = function(self, inputAdjustValue, channelValue)
    self:__CallGenericCommand(
      "RecordingInputAnalogLevel",
      "__RecordingInputAnalogLevelCommand",
      inputAdjustValue,
      channelValue
    )
  end,

  ---
  -- Command Code for "RecordingVolumePoll"
  --
  -- @return A command string for polling the recording volume levels.
  --
  __RecordingVolumePoll = function(self)
    local cmdDelimiter = self.__cmdDelimiter
    local startCharacter = self.__startCharacter

    local staticPart = "?RV"

    local pollString = startCharacter .. staticPart .. cmdDelimiter

    return pollString
  end,

  ---
  -- Generates a command for polling the recording volume levels.
  -- This method constructs a queue command object and stages it for polling
  -- the recording volume levels.
  --
  RecordingVolumePoll = function(self)
    self:__GeneratePollFunction("RecordingVolume")
  end,

  ---
  -- Private method for parsing and updating recording volume response
  --
  -- @param recordingVolumeResponse The response received from the communication module, containing
  -- information about the recording volume levels (e.g., "0250").
  --
  -- @return Two values representing the left and right channel volume levels as integers.
  --
  -- @raise Error If the response is invalid or cannot be converted to integer values.
  --
  __RecordingVolumeUpdate = function(self, recordingVolumeResponse)
    local _, _, leftVolumeMatch, rightVolumeMatch = string.find(
      recordingVolumeResponse,
      self.__matchTable["RecordingVolume"]
    )

    if leftVolumeMatch ~= nil and rightVolumeMatch ~= nil then
      local leftVolume = tonumber(leftVolumeMatch)
      local rightVolume = tonumber(rightVolumeMatch)

      if leftVolume ~= nil and rightVolume ~= nil then
        self:__NotifyListeners("RecordingVolume", leftVolume, rightVolume)
        return { leftVolume, rightVolume }
      else
        error("Error: `__RecordingVolumeUpdate` failed: Unable to convert response to integer values: " ..
        recordingVolumeResponse)
      end
    else
      error("Error: `__RecordingVolumeUpdate` failed: No match found for " .. recordingVolumeResponse)
    end
  end,

  ---
  -- Subscribe command for recording volume levels.
  --
  -- This method subscribes to updates of the recording volume levels and registers a callback function
  -- to be called when the volume levels change.
  --
  -- @param callback A callback function to be called when the recording volume levels change.
  --
  RecordingVolumeSubscribe = function(self, callback)
    self:__SubscribeToGroup("RecordingVolume", callback)
  end,

  ---
  -- Command Code for "ResetArchiveSettingsCommand"
  --
  -- @return A command string that can be sent to reset archive settings. The format of the command
  -- is: [startCharacter]DEAC[cmdDelimiter].
  --
  __ResetArchiveSettingsCommand = function(self)
    local cmdDelimiter = self.__cmdDelimiter
    local startCharacter = self.__startCharacter

    local staticPart = "DEAC"

    local cmdString = startCharacter .. staticPart .. cmdDelimiter
    return cmdString
  end,

  ---
  -- Generates a command for resetting archive settings.
  -- Resets DN-900R’s archive settings to their default values
  --
  ResetArchiveSettingsCommand = function(self)
    self:__CallGenericCommand(
      "ResetArchiveSettings",
      "__ResetArchiveSettingsCommand"
    )
  end,

  --
  -- Command Code for "SetTimerByDayOfWeekCommand"
  --
  -- @param recordTimerSettingValue The desired record timer setting value. Should be between 1 and 30.

  -- @param daysOfWeek The days of the week for the timer. Can be a single day (string) or a list of strings.
  -- If a list of strings is provided, each value must be a valid day of the week and be capitalized.
  --
  -- NOTE: A helper dataset is available when selecting days of the week. This method does not check to
  -- ensure that the provided values are valid days of the week, so using the helper dataset is ideal when
  -- you want to mitigate any potential errors that might be difficult to detect.
  --
  -- @param startTime The start time for the timer in the format "hh:mm".
  --
  -- @return A command string for setting the timer by day of the week.
  --
  -- @raise Error If any of the input values are invalid.
  --
  __SetTimerByDayOfWeekCommand = function(
    self,
    daysOfWeek,
    startTime
  )
    local cmdDelimiter = self.__cmdDelimiter
    local startCharacter = self.__startCharacter
    local staticPart = "ST"

    -- Validate and format daysOfWeek
    local daysOfWeekResult = {}

    local daysOfWeekMap = {
      "Sunday",
      "Monday",
      "Tuesday",
      "Wednesday",
      "Thursday",
      "Friday",
      "Saturday"
    }

    if not daysOfWeek then
      error("Error: __SetTimerByDayOfWeekCommand requires `daysOfWeek` to be provided")
    end

    if not startTime then
      error("Error: __SetTimerByDayOfWeekCommand requires `startTime` to be provided")
    end

    for index, value in ipairs(daysOfWeekMap) do
      daysOfWeekResult[index] = "_"
      if type(daysOfWeek) == "table" then
        for _, dayOfWeek in ipairs(daysOfWeek) do
          if value == dayOfWeek then
            daysOfWeekResult[index] = string.sub(dayOfWeek, 1, 1)
          end
        end
      else
        if value == daysOfWeek then
          daysOfWeekResult[index] = string.sub(daysOfWeek, 1, 1)
        end
      end
    end

    -- Validate and format startTime
    local startTimePattern = "^%d%d:%d%d$"

    if string.match(startTime, startTimePattern) then
      startTime = string.gsub(startTime, ":", "")
    else
      error("Error: `startTime` is invalid; should be in the format 'hh:mm'.")
    end

    local cmdString = startCharacter .. staticPart .. table.concat(daysOfWeekResult) .. startTime .. cmdDelimiter
    return cmdString
  end,

  --
  -- Enqueues a command for setting the archive timer by day of the week and start time.
  -- This method adjusts the scheduled archiving for a specified day and time. Archiving will only occur on
  -- the days as specified by the `daysOfWeek` parameter, and that recording will only occur starting at
  -- `startTime`.
  --
  -- NOTE: A helper dataset is available when selecting days of the week. This method does not check to
  -- ensure that the provided values are valid days of the week, so using the helper dataset is ideal when
  -- you want to mitigate any potential errors that might be difficult to detect.
  --
  -- @param recordTimerSettingValue The desired record timer setting value. Should be between 1 and 30.
  --
  -- @param daysOfWeek The days of the week for the timer. Can be a single day (string) or a list of strings.
  -- If a list of string is provided, each value must be a valid day of the week and be capitalized.
  --
  -- @param startTime The start time for the timer in the format "hh:mm".
  --
  SetTimerByDayOfWeekCommand = function(self, daysOfWeek, startTime)
    self:__CallGenericCommand(
      "SetTimerByDayOfWeek",
      "__SetTimerByDayOfWeekCommand",
      daysOfWeek,
      startTime
    )
  end,
}

return {
  Denon900R = Denon900R,
  DaysOfWeek = DaysOfWeek
}
