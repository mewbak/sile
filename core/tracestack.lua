-- Represents a stack of stack frame objects,
-- which describe the call-stack stack of the currently processed document.
-- Stack frames are stored contiguously, treating this object as an array.
-- Most recent and relevant stack frames are in higher indices, up to #traceStack.
-- Do not manipulate the stack directly, use provided push<Type> and pop methods.
-- There are different types of stack frames, see pushFrame for more details.
local traceStack = {
  -- Stores the frame which was last popped. Reset after a push.
  -- Helps to further specify current location in the processed document.
  afterFrame = nil
}

local function genericFrameToStringHelper(frame)
  frame.file = nil
  frame.lno = nil
  frame.col = nil
  return #frame > 0 and tostring(frame) or ""
end

-- Internal: Call with frame to convert that frame to a string.
-- Takes care of formatting location and calling frame's toStringHelper, if any.
local function frameToString(frame, skipFile)
  local str = ""
  if frame.file and not skipFile then
    str = frame.file .. ":"
  end
  if frame.lno then
    str = str .. frame.lno .. ":"
    if frame.col then
      str = str .. frame.col .. ":"
    end
  end
  str = str .. (str:len() > 0 and " " or "") .. "in "
  if frame.toStringHelper then
    str = str .. frame:toStringHelper()
  else
    str = str .. genericFrameToStringHelper(frame)
  end
  return str
end

local function commandFrameToStringHelper(frame)
  local options = (#frame.options > 0 and tostring(frame.options):gsub("^{", "["):gsub("}$", "]") or "")
  return "\\" .. frame.command .. options
end

local function textFrameToStringHelper(frame)
  local text = frame.text
  if text:len() > 20 then
    text = text:sub(1, 18) .. "…"
  end
  text = text:gsub("\n", "␤"):gsub("\t", "␉"):gsub("\v", "␋")
  return '"' .. text .. '"'
end

-- Internal: Given an collection of frames and an afterFrame, construct and return a human readable info string
-- about the location in processed document. Similar to _frameToLocationString, but takes into account
-- the afterFrame and the fact, that not all frames may carry a location information.
local function formatTraceHead(stack, afterFrame)
  local top = stack[#stack]
  if not top then
    -- Stack is empty, there is not much we can do
    return afterFrame and "after " .. frameToString(afterFrame) or nil
  end
  local info = frameToString(top)
  local locationFrame = top
  -- Not all stack traces have to carry location information.
  -- If the top stack trace does not carry it, find a frame which does.
  -- Then append it, because its information may be useful.
  if not top.lno then
    for i = #stack - 1, 1, -1 do
      if stack[i].lno then
        -- Found a frame which does carry some relevant information.
        locationFrame = stack[i]
        info = info .. " near " .. frameToString(locationFrame, locationFrame.file == top.file)
        break
      end
    end
  end
  -- Print after, if it is in a relevant file
  if afterFrame and (not locationFrame or afterFrame.file == locationFrame.file) then
    info = info .. " after " .. frameToString(afterFrame, true)
  end
  return info
end

-- Push a command frame on to the stack to record the execution trace for debugging.
-- Carries information about the command call, not the command itself.
-- Must be popped with `pop(returnOfPush)`.
function traceStack:pushCommand(command, content, options)
  if not command then
    SU.warn("Command should be specified for SILE.traceStack:pushCommand", true)
  end
  if type(content) == "function" then content = {} end
  return self:pushFrame({
      command = command,
      file = content.file or SILE.currentlyProcessingFile,
      lno = content.lno,
      col = content.col,
      options = options or {},
      toStringHelper = commandFrameToStringHelper
    })
end

-- Push a command frame on to the stack to record the execution trace for debugging.
-- Command arguments are inferred from AST content, any item may be overridden.
-- Must be popped with `pop(returnOfPush)`.
function traceStack:pushContent(content, command)
  if type(content) ~= "table" then
    SU.warn("Content parameter of SILE.traceStack:pushContent must be a table", true)
  end
  command = command or content.command
  if not command then
    SU.warn("Command should be specified or inferable for SILE.traceStack:pushContent", true)
  end
  return self:pushFrame({
      command = command,
      file = content.file or SILE.currentlyProcessingFile,
      lno = content.lno,
      col = content.col,
      options = content.options or {},
      toStringHelper = commandFrameToStringHelper
    })
end

-- Push a text that is going to get typeset on to the stack to record the execution trace for debugging.
-- Must be popped with `pop(returnOfPush)`.
function traceStack:pushText(text)
  return self:pushFrame({
      text = text,
      toStringHelper = textFrameToStringHelper
    })
end

-- Internal: Push-pop balance checking ID
local lastPushId = 0

-- Push complete frame onto the stack.
-- Frame is a table with following optional fields:
-- .file = string - name of the file from which this originates
-- .lno = number - line in the file
-- .col = number - column on the line
-- .toStringHelper = function() that serializes extended information about the frame BESIDES location
function traceStack:pushFrame(frame)
  SU.debug("commandStack", string.rep(".", #self) .. "PUSH(" .. frameToString(frame, false) .. ")")
  self[#self + 1] = frame
  self.afterFrame = nil
  lastPushId = lastPushId + 1
  frame._pushId = lastPushId
  return lastPushId
end

-- Pop previously pushed command from the stack.
-- Return value of `push` function must be provided as argument to check for balanced usage.
function traceStack:pop(pushId)
  if type(pushId) ~= "number" then
    SU.error("SILE.traceStack:pop's argument must be the result value of the corresponding push", true)
  end
  -- First verify that push/pop is balanced
  local popped = self[#self]
  if popped._pushId ~= pushId then
    local message = "Unbalanced content push/pop"
    if SILE.traceback or SU.debugging("commandStack") then
      message = message .. ". Expected " .. popped.pushId .. " - (" .. frameToString(popped) .. "), got " .. pushId
    end
    SU.warn(message, true)
  else
    -- Correctly balanced: pop the frame
    self.afterFrame = popped
    self[#self] = nil
    SU.debug("commandStack", string.rep(".", #self) .. "POP(" .. frameToString(popped, false) .. ")")
  end
end

-- Internal: Call to create a fallback location information, when the stack is empty.
local function fallbackLocation()
  return SILE.currentlyProcessingFile or "<nowhere>"
end

-- Returns short string with most relevant location information for user messages.
function traceStack:locationInfo()
  return formatTraceHead(self, self.afterFrame) or fallbackLocation()
end

-- Returns multiline trace string, with full document location information for user messages.
function traceStack:locationTrace()
  local prefix = "\t"
  local trace = formatTraceHead({ self[#self] } --[[we handle rest of the stack ourselves]], self.afterFrame)
  if not trace then
    -- There is nothing else then
    return prefix .. fallbackLocation() .. "\n"
  end
  trace = prefix .. trace .. "\n"
  -- Iterate backwards, skipping the last element
  for i = #self - 1, 1, -1 do
    local s = self[i]
    trace = trace .. prefix .. frameToString(s) .. "\n"
  end
  return trace
end

return traceStack
