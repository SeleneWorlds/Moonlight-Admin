local Network = require("selene.network")
local Registries = require("selene.registries")

local AdminMenu = {}
local actions = {}
local registryVisualResolvers = {}
local targetResolvers = {}

local supportedParameterTypes = {
    number = true,
    string = true,
    message = true,
    enum = true,
    boolean = true,
    coordinate = true,
    registry = true,
    target = true,
}

local function assertIdentifier(value, label)
    assert(type(value) == "string" and value:match("^[%w_.:-]+$"), label .. " must be a non-empty identifier")
    return value
end

local function normalizeParameter(parameter)
    assert(type(parameter) == "table", "action parameters must be tables")
    local parameterType = parameter.type or "string"
    assert(supportedParameterTypes[parameterType], "unsupported admin action parameter type: " .. tostring(parameterType))

    local normalized = {
        name = assertIdentifier(parameter.name, "parameter name"),
        label = parameter.label or parameter.name,
        type = parameterType,
        required = parameter.required ~= false,
    }
    assert(type(normalized.label) == "string", "parameter label must be a string")

    if parameter.default ~= nil then
        local defaultType = (parameterType == "registry" or parameterType == "target" or parameterType == "message"
            or parameterType == "enum") and "string"
            or parameterType == "coordinate" and "table"
            or parameterType
        assert(type(parameter.default) == defaultType, "parameter default must match its type")
        if parameterType == "coordinate" then
            for _, axis in ipairs({ "x", "y", "z" }) do
                local component = parameter.default[axis]
                assert(
                    type(component) == "number" and component % 1 == 0,
                    "coordinate default " .. axis .. " must be an integer"
                )
            end
        end
        normalized.default = parameter.default
    end
    if parameterType == "number" then
        normalized.min = parameter.min
        normalized.max = parameter.max
        normalized.step = parameter.step
        assert(normalized.min == nil or type(normalized.min) == "number", "parameter min must be a number")
        assert(normalized.max == nil or type(normalized.max) == "number", "parameter max must be a number")
        assert(normalized.step == nil or type(normalized.step) == "number", "parameter step must be a number")
    elseif parameterType == "enum" then
        assert(type(parameter.options) == "table" and #parameter.options > 0, "enum parameter options must be a list")
        normalized.options = {}
        local values = {}
        for _, option in ipairs(parameter.options) do
            assert(type(option) == "table", "enum parameter options must be tables")
            assert(type(option.value) == "string" and option.value ~= "", "enum option value must be a non-empty string")
            assert(type(option.label) == "string" and option.label ~= "", "enum option label must be a non-empty string")
            assert(not values[option.value], "duplicate enum option value: " .. option.value)
            values[option.value] = true
            table.insert(normalized.options, { value = option.value, label = option.label })
        end
        assert(normalized.default == nil or values[normalized.default], "enum parameter default must match an option")
    elseif parameterType == "registry" then
        normalized.registry = assertIdentifier(parameter.registry, "parameter registry")
        assert(parameter.deferred == nil or type(parameter.deferred) == "boolean", "parameter deferred must be a boolean")
        assert(parameter.filter == nil or type(parameter.filter) == "function", "parameter filter must be a function")
        normalized.deferred = parameter.deferred ~= false
        normalized.filter = parameter.filter
    elseif parameterType == "target" then
        normalized.resolver = assertIdentifier(parameter.resolver, "parameter target resolver")
        assert(
            parameter.requireOnline == nil or type(parameter.requireOnline) == "boolean",
            "parameter requireOnline must be a boolean"
        )
        normalized.requireOnline = parameter.requireOnline == true
        assert(parameter.deferred == nil or type(parameter.deferred) == "boolean", "parameter deferred must be a boolean")
        normalized.deferred = parameter.deferred ~= false
    end

    return normalized
end

local function registryOptions(registryName, query, limit, filter)
    local options = {}
    query = query and query:lower() or nil
    for _, entry in pairs(Registries.findAll(registryName)) do
        if filter == nil or filter(entry) then
            local value = entry:getName()
            local label = entry:getMetadata("name")
            if label == nil then
                local succeeded, fieldLabel = pcall(function()
                    return entry:getField("name")
                end)
                if succeeded then
                    label = fieldLabel
                end
            end
            if label == nil or label == "" then
                label = value
            end
            label = tostring(label)
            if query == nil or label:lower():find(query, 1, true) or value:lower():find(query, 1, true) then
                local option = { value = value, label = label }
                local resolver = registryVisualResolvers[registryName]
                if resolver then
                    local succeeded, visual = pcall(resolver, entry)
                    if succeeded and visual ~= nil then
                        assert(type(visual) == "string", "registry visual resolver must return a string or nil")
                        option.visual = visual
                    end
                end
                table.insert(options, option)
            end
        end
    end
    table.sort(options, function(left, right)
        return left.label < right.label
    end)
    while limit and #options > limit do
        table.remove(options)
    end
    return options
end

local function targetOptions(resolverName, player, requireOnline)
    local resolver = assert(targetResolvers[resolverName], "unknown target resolver: " .. resolverName)
    local resolved = resolver(player)
    assert(type(resolved) == "table", "target resolver must return a list")
    local options = {}
    for _, option in ipairs(resolved) do
        assert(type(option) == "table", "target resolver options must be tables")
        assert(type(option.value) == "string", "target resolver option value must be a string")
        assert(type(option.label) == "string", "target resolver option label must be a string")
        assert(option.visual == nil or type(option.visual) == "string", "target resolver option visual must be a string")
        assert(option.offline == nil or type(option.offline) == "boolean", "target resolver option offline must be a boolean")
        assert(option.default == nil or type(option.default) == "boolean", "target resolver option default must be a boolean")
        if not requireOnline or option.offline ~= true then
            table.insert(options, {
                value = option.value,
                label = option.label,
                visual = option.visual,
                offline = option.offline == true,
                default = option.default == true,
            })
        end
    end
    table.sort(options, function(left, right)
        return left.label < right.label
    end)
    return options
end

local function publicDefinition(action, player, sharedTargetOptions)
    local parameters = {}
    for _, parameter in ipairs(action.parameters) do
        local publicParameter = {}
        for key, value in pairs(parameter) do
            if key ~= "filter" then
                publicParameter[key] = value
            end
        end
        if parameter.type == "registry" then
            publicParameter.options = parameter.deferred
                and {}
                or registryOptions(parameter.registry, nil, nil, parameter.filter)
        elseif parameter.type == "target" then
            local optionSet = parameter.resolver .. (parameter.requireOnline and ":online" or ":all")
            publicParameter.optionSet = optionSet
            publicParameter.options = {}
            if sharedTargetOptions[optionSet] == nil then
                local defaultOptions = {}
                for _, option in ipairs(targetOptions(parameter.resolver, player, parameter.requireOnline)) do
                    if option.default then
                        table.insert(defaultOptions, option)
                    end
                end
                sharedTargetOptions[optionSet] = defaultOptions
            end
            if publicParameter.default == nil then
                local defaultOption = sharedTargetOptions[optionSet][1]
                if defaultOption then
                    publicParameter.default = defaultOption.value
                end
            end
        end
        table.insert(parameters, publicParameter)
    end
    return {
        id = action.id,
        label = action.label,
        description = action.description,
        parameters = parameters,
    }
end

local function isAvailable(action, player)
    if action.isAvailable == nil then
        return true
    end
    local succeeded, available = pcall(action.isAvailable, player)
    return succeeded and available == true
end

local function sendActions(player)
    local available = {}
    local sharedTargetOptions = {}
    for _, action in pairs(actions) do
        if isAvailable(action, player) then
            table.insert(available, publicDefinition(action, player, sharedTargetOptions))
        end
    end
    table.sort(available, function(left, right)
        return left.label < right.label
    end)
    Network.sendToPlayer(player, "moonlight-admin:actions", {
        actions = available,
        targetOptions = sharedTargetOptions,
    })
end

local function validateValues(action, supplied, player)
    assert(type(supplied) == "table", "parameters must be an object")
    local values = {}
    for _, parameter in ipairs(action.parameters) do
        local value = supplied[parameter.name]
        if value == nil then
            value = parameter.default
        end
        if value == nil and parameter.type == "target" then
            for _, option in ipairs(targetOptions(parameter.resolver, player, parameter.requireOnline)) do
                if option.default then
                    value = option.value
                    break
                end
            end
        end
        if value == nil then
            assert(not parameter.required, parameter.label .. " is required")
        else
            local valueType = (parameter.type == "registry" or parameter.type == "target" or parameter.type == "message"
                or parameter.type == "enum") and "string"
                or parameter.type == "coordinate" and "table"
                or parameter.type
            assert(type(value) == valueType, parameter.label .. " must be a " .. valueType)
            if parameter.type == "number" then
                assert(parameter.min == nil or value >= parameter.min, parameter.label .. " is below its minimum")
                assert(parameter.max == nil or value <= parameter.max, parameter.label .. " is above its maximum")
            elseif parameter.type == "enum" then
                local found = false
                for _, option in ipairs(parameter.options) do
                    if option.value == value then
                        found = true
                        break
                    end
                end
                assert(found, parameter.label .. " is not valid")
            elseif parameter.type == "coordinate" then
                for _, axis in ipairs({ "x", "y", "z" }) do
                    local component = value[axis]
                    assert(
                        type(component) == "number" and component % 1 == 0,
                        parameter.label .. " " .. axis:upper() .. " must be an integer"
                    )
                end
            elseif parameter.type == "registry" then
                local entry = Registries.findByName(parameter.registry, value)
                assert(entry ~= nil, parameter.label .. " is not valid")
                assert(parameter.filter == nil or parameter.filter(entry), parameter.label .. " is not valid")
            elseif parameter.type == "target" then
                local found = false
                for _, option in ipairs(targetOptions(parameter.resolver, player, parameter.requireOnline)) do
                    if option.value == value then
                        found = true
                        break
                    end
                end
                assert(found, parameter.label .. " is not valid")
            end
            values[parameter.name] = value
        end
    end
    return values
end

function AdminMenu.registerAction(definition)
    assert(type(definition) == "table", "admin action definition must be a table")
    local id = assertIdentifier(definition.id, "action id")
    assert(type(definition.label) == "string" and definition.label ~= "", "action label must be a non-empty string")
    assert(definition.description == nil or type(definition.description) == "string", "action description must be a string")
    assert(type(definition.execute) == "function", "action execute must be a function")
    assert(definition.isAvailable == nil or type(definition.isAvailable) == "function", "action isAvailable must be a function")

    local parameters = {}
    local parameterNames = {}
    for _, parameter in ipairs(definition.parameters or {}) do
        local normalized = normalizeParameter(parameter)
        assert(not parameterNames[normalized.name], "duplicate parameter: " .. normalized.name)
        parameterNames[normalized.name] = true
        table.insert(parameters, normalized)
    end

    actions[id] = {
        id = id,
        label = definition.label,
        description = definition.description,
        parameters = parameters,
        execute = definition.execute,
        isAvailable = definition.isAvailable,
    }
end

function AdminMenu.registerRegistryVisualResolver(registryName, resolver)
    registryName = assertIdentifier(registryName, "registry name")
    assert(type(resolver) == "function", "registry visual resolver must be a function")
    registryVisualResolvers[registryName] = resolver
end

function AdminMenu.registerTargetResolver(name, resolver)
    name = assertIdentifier(name, "target resolver name")
    assert(type(resolver) == "function", "target resolver must be a function")
    targetResolvers[name] = resolver
end

Network.handlePayload("moonlight-admin:request-actions", function(player)
    sendActions(player)
end)

Network.handlePayload("moonlight-admin:search-registry", function(player, payload)
    local action = type(payload.actionId) == "string" and actions[payload.actionId] or nil
    if action == nil or not isAvailable(action, player) or type(payload.parameterName) ~= "string" then
        return
    end
    for _, parameter in ipairs(action.parameters) do
        if parameter.name == payload.parameterName and parameter.type == "registry" and parameter.deferred then
            local query = type(payload.query) == "string" and payload.query or ""
            Network.sendToPlayer(player, "moonlight-admin:registry-options", {
                actionId = action.id,
                parameterName = parameter.name,
                query = query,
                options = registryOptions(parameter.registry, query, 50, parameter.filter),
            })
            return
        end
    end
end)

Network.handlePayload("moonlight-admin:search-target", function(player, payload)
    local action = type(payload.actionId) == "string" and actions[payload.actionId] or nil
    if action == nil or not isAvailable(action, player) or type(payload.parameterName) ~= "string" then
        return
    end
    for _, parameter in ipairs(action.parameters) do
        if parameter.name == payload.parameterName and parameter.type == "target" and parameter.deferred then
            local query = type(payload.query) == "string" and payload.query:lower() or ""
            local matches = {}
            for _, option in ipairs(targetOptions(parameter.resolver, player, parameter.requireOnline)) do
                if query == "" or option.label:lower():find(query, 1, true)
                    or option.value:lower():find(query, 1, true) then
                    table.insert(matches, option)
                    if #matches == 50 then
                        break
                    end
                end
            end
            Network.sendToPlayer(player, "moonlight-admin:target-options", {
                actionId = action.id,
                parameterName = parameter.name,
                query = type(payload.query) == "string" and payload.query or "",
                options = matches,
            })
            return
        end
    end
end)

Network.handlePayload("moonlight-admin:execute", function(player, payload)
    local actionId = payload.actionId
    local action = type(actionId) == "string" and actions[actionId] or nil
    if action == nil or not isAvailable(action, player) then
        Network.sendToPlayer(player, "moonlight-admin:result", {
            actionId = actionId or "",
            success = false,
            message = "Action is not available.",
        })
        return
    end

    local valid, values = pcall(validateValues, action, payload.parameters or {}, player)
    if not valid then
        Network.sendToPlayer(player, "moonlight-admin:result", {
            actionId = action.id,
            success = false,
            message = tostring(values),
        })
        return
    end

    local succeeded, message = pcall(action.execute, player, values)
    local resultMessage
    if succeeded then
        resultMessage = message == nil and "Action completed." or tostring(message)
    else
        resultMessage = tostring(message)
    end
    Network.sendToPlayer(player, "moonlight-admin:result", {
        actionId = action.id,
        success = succeeded,
        message = resultMessage,
    })
end)

return AdminMenu
