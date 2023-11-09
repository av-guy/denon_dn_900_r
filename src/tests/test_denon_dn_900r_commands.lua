---@diagnostic disable: lowercase-global

LUAUNIT = require("luaunit")

local DenonModule = require("src.lib.denon_dn_900r_v_1_0_0")
local DenonDN900R = DenonModule.Denon900R
local DaysOfWeek = DenonModule.DaysOfWeek

local UnitTestResults = {
  SUCCESS = 0,
  ERROR = 1
}

function createInstance()
  return DenonDN900R:New()
end

-- https://gist.githubusercontent.com/justnom/9816256/raw/d38c3377d674d77101f16791f90496e597591320/table_to_string.lua

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

local function genericMethodTest(driver, commandName, methodType, ...)
  local args = { ... }
  local method = driver["__" .. commandName .. methodType]

  local noError, value = pcall(function()
    return method(driver, table.unpack(args))
  end)

  if noError then
    return value, nil
  else
    return nil, value
  end
end

local function commandMethodTest(driver, commandName, ...)
  return genericMethodTest(driver, commandName, "Command", ...)
end

local function updateMethodTest(driver, commandName, ...)
  return genericMethodTest(driver, commandName, "Update", ...)
end

local function runTestOverValues(valuesTable, commandName, testMethod)
  local driverInstance = DenonDN900R:New()

  for _, values in ipairs(valuesTable) do
    local callStatus = values.Status
    local returnValue = values.ReturnValue

    local result, err = testMethod(
      driverInstance,
      commandName,
      table.unpack(values.Args)
    )

    if err ~= nil then
      if callStatus ~= UnitTestResults.ERROR then
        error("Unexpected error for " .. tableToString(values.Args) .. ": " .. err)
      end
    elseif result ~= nil then
      if callStatus ~= UnitTestResults.SUCCESS then
        error("Unexpected success for " .. tableToString(values.Args))
      else
        if type(returnValue) == "function" then
          returnValue(table.unpack(result))
        else
          LUAUNIT.assertEquals(result, returnValue)
        end
      end
    end
  end
end

function testAdminLoginCommand()
  local valuesTable = {
    {
      Args = {},
      Status = UnitTestResults.ERROR
    },
    {
      Args = { "" },
      Status = UnitTestResults.ERROR
    },
    {
      Args = { "password" },
      Status = UnitTestResults.SUCCESS,
      ReturnValue = "@0?LIpassword\r"
    }
  }

  runTestOverValues(valuesTable, "AdminLogin", commandMethodTest)
end

function testAdminLoginUpdate()
  local valuesTable = {
    {
      Args = { "@0LIOK\r" },
      Status = UnitTestResults.SUCCESS,
      ReturnValue = "Success"
    },
    {
      Args = { "@0LING\r" },
      Status = UnitTestResults.SUCCESS,
      ReturnValue = "Failed"
    },
    {
      Args = { "dfddjf\r" },
      Status = UnitTestResults.ERROR,
      ReturnValue = nil
    }
  }

  runTestOverValues(valuesTable, "AdminLogin", updateMethodTest)
end

function testAlbumTitlePoll()
  local Denon = DenonDN900R:New()
  local albumTitlePoll = Denon:__AlbumTitlePoll()

  LUAUNIT.assertEquals(albumTitlePoll, "@0?al\r")
end

function testAlbumTitleUpdate()
  local valuesTable = {
    {
      Args = { "@0alMyAlbumTitle\r" },
      Status = UnitTestResults.SUCCESS,
      ReturnValue = "MyAlbumTitle"
    },
    {
      Args = { "dfdadsfs\r" },
      Status = UnitTestResults.ERROR,
    }
  }

  runTestOverValues(valuesTable, "AlbumTitle", updateMethodTest)
end

function testArchiveModeCommand()
  local valuesTable = {
    {
      Args = { "Auto" },
      Status = UnitTestResults.SUCCESS,
      ReturnValue = "@0ARAT\r"
    },
    {
      Args = { "Scheduled" },
      Status = UnitTestResults.SUCCESS,
      ReturnValue = "@0ARSC\r"
    },
    {
      Args = { "Off" },
      Status = UnitTestResults.SUCCESS,
      ReturnValue = "@0AR01\r"
    },
    {
      Args = { "dfdfd" },
      Status = UnitTestResults.ERROR
    },
    {
      Args = {},
      Status = UnitTestResults.ERROR
    },
  }

  runTestOverValues(valuesTable, "ArchiveModeSet", commandMethodTest)
end

function testArchiveModePoll()
  local Denon = DenonDN900R:New()
  local archiveModePoll = Denon:__ArchiveModePoll()

  LUAUNIT.assertEquals(archiveModePoll, "@0?AR\r")
end

function testArchiveModeUpdate()
  local valuesTable = {
    {
      Args = { "@0ARAT\r" },
      Status = UnitTestResults.SUCCESS,
      ReturnValue = "Auto"
    },
    {
      Args = { "@0ARSC\r" },
      Status = UnitTestResults.SUCCESS,
      ReturnValue = "Scheduled"
    },
    {
      Args = { "@0AR01\r" },
      Status = UnitTestResults.SUCCESS,
      ReturnValue = "Off"
    }
  }

  runTestOverValues(valuesTable, "ArchiveMode", updateMethodTest)
end

function testSetTimerByDayOfWeekCommand()
  local valuesTable = {
    {
      Args = { "Monday", "12:30" },
      Status = UnitTestResults.SUCCESS,
      ReturnValue = "@0ST_M_____1230\r"
    },
    {
      Args = { "Saturday", "13:30" },
      Status = UnitTestResults.SUCCESS,
      ReturnValue = "@0ST______S1330\r"
    },
    {
      Args = { { "Monday", "Saturday" }, "13:30" },
      Status = UnitTestResults.SUCCESS,
      ReturnValue = "@0ST_M____S1330\r"
    },
    {
      Args = { nil, "12:30" },
      Status = UnitTestResults.ERROR,
    },
    {
      Args = { "Monday", nil },
      Status = UnitTestResults.ERROR,
    },
    {
      Args = { DaysOfWeek.MONDAY, "14:40" },
      Status = UnitTestResults.SUCCESS,
      ReturnValue = "@0ST_M_____1440\r"
    },
    {
      Args = { { DaysOfWeek.MONDAY, DaysOfWeek.SATURDAY }, "14:40" },
      Status = UnitTestResults.SUCCESS,
      ReturnValue = "@0ST_M____S1440\r"
    }
  }

  runTestOverValues(valuesTable, "SetTimerByDayOfWeek", commandMethodTest)
end

function testArchiveTimerPoll()
  local Denon = DenonDN900R:New()
  local archiveTimerPoll = Denon:__ArchiveTimerSettingPoll()

  LUAUNIT.assertEquals(archiveTimerPoll, "@0?Sh\r")
end

function testArchiveTimerUpdate()
  local valuesTable = {
    {
      Args = { "@0asDW_MT____1230\r" },
      Status = UnitTestResults.SUCCESS,
      ReturnValue = function(daysOfWeekList, startTime)
        if daysOfWeekList == nil then
          error("`daysOfWeekList` argument is nil!")
        end

        local expected = { "Monday", "Tuesday" }

        for index, value in ipairs(expected) do
          LUAUNIT.assertEquals(daysOfWeekList[index], value)
        end

        LUAUNIT.assertEquals(startTime, "12:30")
      end
    },
  }

  runTestOverValues(valuesTable, "ArchiveTimerSetting", updateMethodTest)
end

function testArchiveClearSettingCommand()
  local valuesTable = {
    {
      Args = { "On" },
      Status = UnitTestResults.SUCCESS,
      ReturnValue = "@0CA00\r"
    },
    {
      Args = { "Off" },
      Status = UnitTestResults.SUCCESS,
      ReturnValue = "@0CA01\r"
    },
    {
      Args = {},
      Status = UnitTestResults.ERROR,
    },
    {
      Args = { "LDKFDJFLJF" },
      Status = UnitTestResults.ERROR,
    },
    {
      Args = { 123 },
      Status = UnitTestResults.ERROR,
    },
  }

  runTestOverValues(valuesTable, "ArchiveClearSetting", commandMethodTest)
end

function testArchiveClearSettingPoll()
  local Denon = DenonDN900R:New()
  local archiveClearSettingPoll = Denon:__ArchiveClearSettingPoll()

  LUAUNIT.assertEquals(archiveClearSettingPoll, "@0?CA\r")
end

function testArchiveClearSettingUpdate()
  local valuesTable = {
    {
      Args = { "@0CA00\r" },
      Status = UnitTestResults.SUCCESS,
      ReturnValue = "On"
    },
    {
      Args = { "@0CA01\r" },
      Status = UnitTestResults.SUCCESS,
      ReturnValue = "Off"
    },
    {
      Args = { "fdfadsfsd" },
      Status = UnitTestResults.ERROR,
    }
  }

  runTestOverValues(valuesTable, "ArchiveClearSetting", updateMethodTest)
end

function testAutoDeletionCommand()
  local valuesTable = {
    {
      Args = { 1 },
      Status = UnitTestResults.SUCCESS,
      ReturnValue = "@0AD01\r"
    },
    {
      Args = { 24 },
      Status = UnitTestResults.SUCCESS,
      ReturnValue = "@0AD24\r"
    },
    {
      Args = { "Off" },
      Status = UnitTestResults.SUCCESS,
      ReturnValue = "@0ADOF\r"
    },
    {
      Args = {},
      Status = UnitTestResults.ERROR,
    },
    {
      Args = { "LDKFDJFLJF" },
      Status = UnitTestResults.ERROR,
    }
  }

  runTestOverValues(valuesTable, "AutoDeletion", commandMethodTest)
end

function testAutoDeletionPoll()
  local Denon = DenonDN900R:New()
  local autoDeletionPoll = Denon:__AutoDeletionPoll()

  LUAUNIT.assertEquals(autoDeletionPoll, "@0?AD\r")
end

function testAutoDeletionUpdate()
  local valuesTable = {
    {
      Args = { "@0AD01\r" },
      Status = UnitTestResults.SUCCESS,
      ReturnValue = 1
    },
    {
      Args = { "@0AD24\r" },
      Status = UnitTestResults.SUCCESS,
      ReturnValue = 24
    },
    {
      Args = { "fdfadsfsd" },
      Status = UnitTestResults.ERROR,
    }
  }

  runTestOverValues(valuesTable, "AutoDeletion", updateMethodTest)
end

function testRecordingInputAnalogLevelCommand()
  local valuesTable = {
    {
      Args = { -2.0, "Left" },
      Status = UnitTestResults.SUCCESS,
      ReturnValue = "@0ltL-20\r"
    },
    {
      Args = { 2.0, "Right" },
      Status = UnitTestResults.SUCCESS,
      ReturnValue = "@0ltR+20\r"
    },
    {
      Args = {},
      Status = UnitTestResults.ERROR,
    },
    {
      Args = { nil, "Right" },
      Status = UnitTestResults.ERROR,
    },
    {
      Args = { -2.0, nil },
      Status = UnitTestResults.ERROR,
    },
    {
      Args = { -20, "Right "},
      Status = UnitTestResults.ERROR
    },
    {
      Args = { -1.0, "Nope" },
      Status = UnitTestResults.ERROR
    }
  }

  runTestOverValues(valuesTable, "RecordingInputAnalogLevel", commandMethodTest)
end

function testRecordingVolumePoll()
  local Denon = DenonDN900R:New()
  local recordingVolumePoll = Denon:__RecordingVolumePoll()

  LUAUNIT.assertEquals(recordingVolumePoll, "@0?RV\r")
end

function testRecordingVolumeUpdate()
  local valuesTable = {
    {
      Args = { "@0RV0120\r" },
      Status = UnitTestResults.SUCCESS,
      ReturnValue = function(leftVolume, rightVolume)
        LUAUNIT.assertEquals(leftVolume, 1)
        LUAUNIT.assertEquals(rightVolume, 20)
      end
    }
  }

  runTestOverValues(valuesTable, "RecordingVolume", updateMethodTest)
end

os.exit(LUAUNIT.LuaUnit.run())
