# (TF2) Weapon Manager

This is a highly flexible and complex plugin that allows users to manage weapons, by allowing them to:
- Create definitions for existing TF2 weapons in-game that aren't typically exposed to the user through the loadout system
- Toggle a loadout menu that is accessible via the `!loadout` command
- Block weapons from being equipped on classes
- Allow weapons to be equipped not only in other classes, but in other slots completely
- Modify the type of a specific weapon by modifying their entity classname (for example, the Degreaser could be a tf_weapon_shotgun instead of a tf_weapon_flamethrower)
- Create definitions for weapons through [nosoop's Custom Weapons X (CWX)](https://github.com/nosoop/SM-TFCustomWeaponsX) (this plugin must be loaded for custom weapons to be supported, however it is not necessary for core functionality)

This plugin is designed to be used either with in-game commands, through modifying a config, or programmatically.

## How to use
Users may create definitions for TF2 econ entities (wearables or weapons), which are referenced by either their name as specified in `items_game.txt` (usually it is the weapon or wearable's in-game name) or [their item definition index](https://wiki.alliedmods.net/Team_fortress_2_item_definition_indexes). Users may also create definitions for specific tags that aren't linked to any weapons; these definitions are designed to be inherited by other definitions through a copy-paste mechanism.

Definitions are defined within config files in `addons/sourcemod/configs/weapon_manager/`, with an `autosave.cfg` being created whenever you save on demand, or on plugin end. Each individiual definition is listed within the `Loadout` key. Within each definition, you may specify properties, which are prefixed with `#`:
- `#inherits` - if specified, this definition will inherit all data from an existing definition (MUST BE LISTED BEFORE THIS DEFINITION!)
- `#classes` - specify what classes and their respective slot this weapon is for. More information can be found in `example.cfg`.
- `#classname` - if a valid classname is provided, the entity spawned will use the desired entity classname instead. If this is empty, the plugin will use the entity's default classname. This property is ignored for CWX weapons.
- `#iscwx` - if this is a CWX definition, specify the UID for the definition from your CWX config here. Leave this property empty if this is a native TF2 weapon.
- `#default` - if a weapon in any slot this weapon is toggled for is blocked, this weapon will be automatically equipped if set to 1. Set this property to 0 if you do not want this behaviour.
- `#visible` - set this property to 0 (it is 1 by default) if you do not want this definition being listed in the `!loadout` menu.
- `#medieval` - set this property to 1 if you want this definition to be allowed in Medieval Mode. Set this property to 0 to block it. Set this property to -1 or leave it blank to use default TF2 behaviour for this weapon. This has no effect on CWX weapons besides preventing it from being listed in the `!loadout` menu.

Currently, there are three methods of manipulating definitions, shown below.

## In-game
There are plenty of in-game admin commands (feel free to inform me if you would like these to be expanded) in order to manipulate definitions. When conducting operations on existing definitions which modify weapons or wearables, you may specify them by either naming them or providing their item definition index - this should be resolved internally.
- `weapon_write [configname]` - writes all definitions to a config file, (autosave.cfg by default, `configname`.cfg if specified). The extension must be omitted.
- `(weapon_loadconfig | weapon_load) configname` - loads definitions from an existing config file. The extension must be omitted.
- `(weapon_listdefinitions | weapon_listdefs | weapon_list) [class] [slot]` - lists the names of all current definitions. You may specify a class and slot to limit the scope of the definitions returned.
- `weapon_add (name | item definition index) [inherits]` - define a new definition by weapon/wearable name, item definition index, or as a tag. If specified, this definition's data can be inherited from another existing definition. If you want this definition to act as a CWX weapon, you must modify it further using weapon_modify and modify the `iscwx` property.
- `(weapon_remove | weapon_delete | weapon_del) (name | item definition index)` - removes an existing definition by weapon/wearable name, item definition index, or custom tag name (applies for CWX weapons too).
- `weapon_modify (name | item definition index) property value` - modifies a property of an existing definition. If `value` is `true` or `false`, these will be resolved to `1` and `0` respectively. The following properties can be modified: `classname`, `iscwx`, `default`, `visible`, `medieval`. To toggle which slots this definition can be used in, you must use the `weapon_toggleslot` or `weapon_disable` commands. Read this repository's `example.cfg` for more information on these properties.
- `weapon_refresh` - reparses all definitions using the current set config.
- `(weapon_toggleshot | weapon_toggle) (name | item definition index) class slot value` - toggles a definition for a specific class and its slot. If `value` is `true` or `false`, these will be resolved to `1` and `0` respectively.
- `(weapon_disable | weapon_block) (name | item definition index) class` - disables a definition entirely for a desired class.
- `(weapon_listdefinition | weapon_listdef) (name | item definition index)` - lists the name, status and properties of an existing definition.
- `weapon_giveto player slot (name | item definition index) [persist]` - Give a weapon immediately to a player. You can choose whether it should persist.
- `weapon_givetonext player class slot (name | item definition index)` - Assign a weapon to a player, which will be equipped on resupply.
- `weapon_unequipfrom player class slot` - Unequip a weapon from a player, which will take place on resupply.

If toggled (which can be configured through `weapon_manager.cfg` in your `configs` directory), all players can also have access to the following general-purpose commands:
- `loadout` - toggle the loadout menu, giving users the ability to equip a weapon for a specific slot with their current class.
- `gimme slot (name | item definition index) [persist]` - Give a weapon immediately to yourself. You can choose whether it should persist.
- `gimmenext class slot (name | item definition index)` - Assign a weapon to yourself, which will be equipped on resupply.
- `unequip class slot` - Unequip a weapon from yourself, which will take place on resupply.

When using the in-game commands, the following classes are available:
- "scout" for Scout
- "soldier" for Soldier
- "pyro" for Pyro
- "demoman", "demo" for Demoman
- "heavy", "heavyweaponsguy", "hwg" for Heavy Weapons Guy
- "engineer", "engi", "engie" for Engineer
- "medic" for Medic
- "sniper" for Sniper
- "spy" for Spy

When using the in-game commands and you must provide a slot, you must use the following values:
- 0 for Primary
- 1 for Secondary
- 2 for Melee
- 3 for Disguise Kit/Construction PDA
- 4 for Watch/Deconstruction PDA

## Config Manipulation
As mentioned earlier, config files are defined in `addons/sourcemod/configs/weapon_manager/`, denoted with the `*.cfg` extension. These are `KeyValues` pairs. These may be modified whilst the plugin is running, and you can use the `(write_loadconfig | write_load)`/`write_refresh` commands to reload them in-game. See `example.cfg` for more specification. For details on specifying which config is loaded on plugin start (by default it will search for `autosave.cfg`), read the **Settings** section.

## Natives
Check out `./scripting/include/weapon_manager.inc` to see a wide range of natives. I highly recommend you use these natives if you are working with weapon code in your own plugins, as due to many hacks being used with weapons in custom slots, traditional methods of finding weapons may lead to you modifying the wrong weapon entirely.

## Settings
By default, this plugin will search for `autosave.cfg` on plugin load, to load any definitions. This is written to on plugin end or on demand (using `weapon_write` or the native `WeaponManager_Write(const char[] cfg)`). However, using a config file located at `addons/sourcemod/configs/weapon_manager.cfg`, you may specify the default config path using the `"defaultconfig"` key. There are also available numerous other properties for server owners. See `addons/sourcemod/configs/weapon_manager.cfg` for more details.

## Miscellaneous
This plugin also exposes a ConVar for server operators to modify either in the server console or with the `sm_cvar` command - `weaponmanager_medievalmode`. This can be used to modify whether the server is using Medieval Mode or not. Plugin developers are advised to toggle Medieval Mode by changing this ConVar's value.

## Notes
While equipping any weapon in their typically designated slots should be completely functional and should not have any errors, weapons for different-than-intended classes and ESPECIALLY in custom slots too are HIGHLY LIKELY to break and functionality should be taken with a grain of salt. This plugin already implements loads of hacks in order to get this to work, but the overall concept of weapons in custom slots breaks a lot of conventions with how TF2 works behind the scenes. This plugin will not address issues beyond basic ammo control (weapons that use different ammo systems, such as the Gas Passer, are much more prone to breaking) as it is out of the scope of this plugin, so it is up to plugin developers to address these.

## Known bugs
- Sappers don't work in custom slots.
- Sappers don't equip nicely if using the equip commands (the persist command/native after loadout is still functional).
- Some weapons have incorrect ammo/clip sizes due to the ammo attributes TF2 uses internally. In the future I may write a plugin that will replace these attributes with custom attributes for individual weapons, rather than for primary/secondary ammo.
- Custom slot weapons equipped in Spy's Sapper/PDA slots are likely to crash the server or your client.
- Custom slot weapons equipped in the Spy's Sapper slot are not highly likely to work due to the weapon being removed randomly.
- If you equip a weapon which is blocked in your real inventory and there is no default weapon to use, and hit resupply, you will switch weapons due to the generation of a new weapon. This isn't really a massive bug, but is the consequence of internal code changes last-minute. (If you are more nerdy, I was originally detouring `CTFPlayer::ItemsMatch()` where I could have handled this, but due to issues with Linux I switched to `CTFPlayer::GetLoadoutItem()` which is a lot more restrictive.)
- If you equip a weapon that is blocked in your real inventory and the default weapon is a CWX weapon, you will have to switch weapons using the loadout menu or change classes before switching weapons in your real TF2 inventory, otherwise the CWX weapon will persist. (Again, if you are more nerdy, this is also a result of not detouring `CTFPlayer::ItemsMatch()`, and CWX also using `CTFPlayer::GetLoadoutItem()`. I may look again into detouring `CTFPlayer::ItemsMatch()` in the future.)
- If TF2 weapons are toggled to be allowed on Medieval Mode when they usually aren't whilst playing Medieval Mode, you cannot equip them through the TF2 inventory. I'm currently waiting for a pull-request for tf2attributes to be accepted in order to deal with this.
- If you equip a CWX weapon using the `!gimme` command and you choose for it to persist, the weapon will be re-created on 1st resupply.

You may have noticed that a lot of these bugs are specific to Spy. Unfortunately, at the current moment, Spy's manipulation is currently limited. This may be reviewed in the future.

## Future ideas (if I ever get around to them)
- Cosmetics support
- Taunts support
- My own framework for custom weapons/wearables
- Strange weapon support for inhibited weapons
- Supporting dropped weapons

## Dependencies
This plugin is compiled using SourceMod 1.12, but should work under SourceMod 1.11.

The following external dependencies are mandatory for this plugin to function:
- [FlaminSarge's TF2Attributes](https://github.com/FlaminSarge/tf2attributes)
- [nosoop's TF2 Econ Data](https://github.com/nosoop/SM-TFEconData)

The following external dependencies are advisory and may be utilised to improve plugin functionality, but not mandatory:
- [nosoop's Custom Weapons X (CWX)](https://github.com/nosoop/SM-TFCustomWeaponsX) - if loaded, this plugin can also work with custom weapon definitions, so long as they are defined in your CWX config file(s) and your desired definitions have the `#iscwx` property filled correctly.
