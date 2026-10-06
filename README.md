## About this Repository

This is a Selene bundle implementing an extensible admin menu for Selene.

Server bundles can depend on `moonlight-admin` and register actions from Lua:

```lua
local AdminMenu = require("moonlight-admin.server.lua.admin_menu")

AdminMenu.registerAction({
    id = "my-bundle:example",
    label = "Example Action",
    description = "An optional explanation shown in the menu.",
    parameters = {
        { name = "count", label = "Count", type = "number", default = 1, min = 1 },
        { name = "message", label = "Message", type = "message" },
        {
            name = "level",
            label = "Level",
            type = "enum",
            options = {
                { value = "low", label = "Low" },
                { value = "high", label = "High" },
            },
        },
        { name = "enabled", label = "Enabled", type = "boolean", default = true },
        { name = "destination", label = "Destination", type = "coordinate" },
        { name = "race", label = "Race", type = "registry", registry = "illarion:races" },
        { name = "target", label = "Target", type = "target", resolver = "my-bundle:targets" },
    },
    isAvailable = function(player)
        return true
    end,
    execute = function(player, parameters)
        -- Perform the server-side action here.
        return "Done."
    end,
})
```

Supported parameter types are `number`, `string`, `message`, `boolean`, `enum`, `coordinate`, `registry`, and `target`.
Message parameters accept strings and span the full width of the action form.
Enum parameters render a dropdown from their static `options` list and submit the selected string value.
Coordinate parameters submit an `{ x, y, z }` table and can be entered manually or
selected from the world with the tile picker.
Registry parameters are populated from the named Selene registry and submit the
selected entry's identifier. Registry options are not included in the initial action
payload; they are searched server-side and returned in sets of at most 50 matches.
Target parameters use named, player-aware resolvers.
`isAvailable` is optional and controls both visibility and execution authorization.
Parameter values are validated server-side before `execute` is called.

A bundle can add previews to options from a registry:

```lua
AdminMenu.registerRegistryVisualResolver("illarion:races", function(entry)
    return "my-bundle:visuals/" .. entry:getMetadata("id")
end)
```

The resolver returns a Selene visual identifier or `nil` for no preview.

Target resolvers return searchable options and may also attach visuals:

```lua
AdminMenu.registerTargetResolver("my-bundle:targets", function(player)
    return {
        { value = "online-id", label = "Online Character", visual = "my-bundle:character", default = true },
        { value = "offline-id", label = "Offline Character", offline = true },
    }
end)
```

Options marked `offline = true` are hidden until the parameter's **Include Offline**
switch is enabled. A resolver may mark one option as `default = true`; dynamic target
defaults are deduplicated in the initial payload and applied in both the menu and
server-side validation. Complete target lists are searched on demand. Set
`requireOnline = true` on a target parameter to exclude offline options and hide the
**Include Offline** switch.
