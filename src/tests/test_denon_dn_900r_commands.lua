---@diagnostic disable: lowercase-global

LUAUNIT = require("luaunit")

local DenonDN900R = require("src.lib.denon_dn_900r_v_1_0_0")

local UnitTestResults = {
  SUCCESS = 0,
  ERROR = 1
}

function createInstance()
  return DenonDN900R:New()
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
  return genericMethodTest(driver, commandName, "Update",...)
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
        error("Unexpected error for " .. table.concat(values.Args) .. ": " .. err)
      end
    elseif result ~= nil then
      if callStatus ~= UnitTestResults.SUCCESS then
        error("Unexpected success for " .. table.concat(values.Args))
      else
        LUAUNIT.assertEquals(result, returnValue)
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
      Args = {"@0LIOK\r"},
      Status = UnitTestResults.SUCCESS,
      ReturnValue = "Success"
    },
    {
      Args = {"@0LING\r"},
      Status = UnitTestResults.SUCCESS,
      ReturnValue = "Failed"
    },
    {
      Args = {"dfddjf\r"},
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

os.exit(LUAUNIT.LuaUnit.run())
