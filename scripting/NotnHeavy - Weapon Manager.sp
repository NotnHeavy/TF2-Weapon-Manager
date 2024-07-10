//////////////////////////////////////////////////////////////////////////////
// MADE BY NOTNHEAVY. USES GPL-3, AS PER REQUEST OF SOURCEMOD               //
//////////////////////////////////////////////////////////////////////////////

// Things can only get better!

// This uses nosoop's TF2 Econ Data plugin:
// https://github.com/nosoop/SM-TFEconData

// This plugin also uses FlaminSarge's tf2attributes (further expanded by nosoop):
// https://github.com/FlaminSarge/tf2attributes

// This plugin can also utilise nosoop's Custom Weapons X, if desired:
// https://github.com/nosoop/SM-TFCustomWeaponsX

#pragma semicolon true 
#pragma newdecls required

#include <sourcemod>
#include <sdkhooks>
#include <tf2_stocks>
#include <dhooks>

#include "tf_item_constants"

#include <third_party/tf_econ_data>
#include <third_party/tf2attributes>

#undef REQUIRE_PLUGIN
#include <third_party/cwx>
#define REQUIRE_PLUGIN

#define AUTOSAVE_PATH "addons/sourcemod/configs/weapon_manager/autosave.cfg"
#define GLOBALS_PATH "addons/sourcemod/configs/weapon_manager.cfg"

#define MAX_SLOTS           9 // engineer destruction PDA is 6, assume from there
#define NAME_LENGTH         64
#define ENTITY_NAME_LENGTH  64
#define MAX_WEAPONS         48

#define PLUGIN_NAME "NotnHeavy - Weapon Manager"

//////////////////////////////////////////////////////////////////////////////
// PLUGIN INFO                                                              //
//////////////////////////////////////////////////////////////////////////////

public Plugin myinfo =
{
    name = PLUGIN_NAME,
    author = "NotnHeavy",
    description = "A loadout manager intended to be flexible, for server owners and plugin creators.",
    version = "1.0",
    url = "none"
};

//////////////////////////////////////////////////////////////////////////////
// MATH FUNCTIONS                                                           //
//////////////////////////////////////////////////////////////////////////////

int min(int x, int y)
{
    return ((x > y) ? y : x);
}

//////////////////////////////////////////////////////////////////////////////
// TF2 DATA                                                                 //
//////////////////////////////////////////////////////////////////////////////

#define MAX_AMMO_SLOTS  32
#define UNUSED_SLOT     TF_AMMO_COUNT

enum
{
	AE_UNDEFINED = -1,

	AE_NORMAL = 0,
	AE_RARITY1 = 1,			// Genuine
	AE_RARITY2 = 2,			// Customized (unused)
	AE_VINTAGE = 3,			// Vintage has to stay at 3 for backwards compatibility
	AE_RARITY3,				// Artisan
	AE_UNUSUAL,				// Unusual
	AE_UNIQUE,
	AE_COMMUNITY,
	AE_DEVELOPER,
	AE_SELFMADE,
	AE_CUSTOMIZED,			// (unused)
	AE_STRANGE,
	AE_COMPLETED,
	AE_HAUNTED,
	AE_COLLECTORS,
	AE_PAINTKITWEAPON,

	AE_RARITY_DEFAULT,
	AE_RARITY_COMMON,
	AE_RARITY_UNCOMMON,
	AE_RARITY_RARE,
	AE_RARITY_MYTHICAL,
	AE_RARITY_LEGENDARY,
	AE_RARITY_ANCIENT,

	AE_MAX_TYPES,
	AE_DEPRECATED_UNIQUE = 3,
};

enum
{
	TF_AMMO_DUMMY = 0,    // Dummy index to make the CAmmoDef indices correct for the other ammo types.
	TF_AMMO_PRIMARY,
	TF_AMMO_SECONDARY,
	TF_AMMO_METAL,
	TF_AMMO_GRENADES1,
	TF_AMMO_GRENADES2,
	TF_AMMO_GRENADES3,    // Utility Slot Grenades
	TF_AMMO_COUNT,

	//
	// ADD NEW ITEMS HERE TO AVOID BREAKING DEMOS
	//
};

enum powerupsize_t
{
	POWERUP_SMALL,
	POWERUP_MEDIUM,
	POWERUP_FULL,

	POWERUP_SIZES,
};

static float PackRatios[view_as<int>(POWERUP_SIZES)] =
{
	0.2,	// SMALL
	0.5,	// MEDIUM
	1.0,	// FULL
};

static float g_flDispenserAmmoRates[4] = 
{
	0.0,
	0.2,
	0.3,
	0.4
};

//////////////////////////////////////////////////////////////////////////////
// GLOBALS                                                                  //
//////////////////////////////////////////////////////////////////////////////

#define NULL_DEFINITION (view_as<Definition>(0xFFFFFFFF))
#define MAXENTITIES     2048

static int g_MaxAmmo[view_as<int>(TFClass_Engineer) + 1][TF_AMMO_COUNT];

static StringMap g_Definitions; // Used with enum struct definitions.
static StringMapSnapshot g_DefinitionsSnapshot; // Used with methodmap definitions.

static Definition g_DefaultDefinitions[view_as<int>(TFClass_Engineer) + 1][MAX_SLOTS];
static char g_DefaultDefinitionBuffers[view_as<int>(TFClass_Engineer) + 1][MAX_SLOTS][ENTITY_NAME_LENGTH];

enum struct definitionbyindex_t
{
    // I can't specify Definition here but I can as a global type?
    // What?
    /*Definition*/ any m_Object;
    bool m_bToggled;
}
static definitionbyindex_t g_DefinitionsByIndex[65536];

enum struct entity_t
{
    int reference;
    int slot;
    int m_hFakeSlotReference;

    // Cached.
    int m_iPrimaryAmmoType;
}
static entity_t g_EntityData[MAXENTITIES + 1];

static DynamicDetour DHooks_CTFPlayer_GetLoadoutItem;
static DynamicDetour DHooks_CTFPlayer_ManageRegularWeapons;
static DynamicDetour DHooks_CTFPlayer_ValidateWeapons;
static DynamicDetour DHooks_CTFPlayer_GetMaxAmmo;
static DynamicDetour DHooks_CTFPlayer_Spawn;
static DynamicDetour DHooks_CTFAmmoPack_PackTouch;
static DynamicDetour DHooks_CAmmoPack_MyTouch;
static DynamicDetour DHooks_CObjectDispenser_DispenseAmmo;

static Handle SDKCall_CTFPlayer_EquipWearable;
static Handle SDKCall_CTFPlayer_GiveNamedItem;
static Handle SDKCall_CBaseCombatWeapon_Deploy;

static bool g_LoadedCWX = false;
static bool g_AllLoaded = false;

static bool g_bWhitelist = false;
static bool g_bLoadDefaults = true;
static bool g_bFilterBotkiller = true;
static bool g_bFilterFestive = true;
static bool g_bBlockUnlisted = true;
static bool g_bCreateMiscDefs = true;

static char g_szCurrentPath[PLATFORM_MAX_PATH];
static bool g_bPrintAllDefs = false;

enum LoadoutOptions_t
{
    LOADOUT_SILENT = -1,
    LOADOUT_OFF,
    LOADOUT_ADMIN,
    LOADOUT_ON
};
static LoadoutOptions_t g_eLoadoutMenu = LOADOUT_ON;
static LoadoutOptions_t g_eCommands = LOADOUT_ON;

static StringMap g_Classes;
static StringMap g_StockWeaponNames;
static ArrayList g_StockItems;

static GlobalForward g_LoadedDefinitionsForward;
static GlobalForward g_ConstructingLoadout;
static GlobalForward g_ConstructingLoadoutPost;

static int CUtlVector_m_Size;
static int CTFWearable_m_bAlwaysAllow;
static int CEconEntity_m_iItemID; // technically CEconItemView::m_iItemID, but we're working with entities.
static int CTFWeaponBase_m_eStatTrakModuleType;
static int CTFWeaponBase_m_eStrangeType;

static ConVar weaponmanager_medievalmode;

//////////////////////////////////////////////////////////////////////////////
// SLOT CONVERSION                                                          //
//////////////////////////////////////////////////////////////////////////////

// TF2 -> Inventory methodmap
// Cosmetics must still be handled separately - they are always 8.
int TF2ToLoadout(int tf2slot, any class)
{
    switch (class)
    {
        case TFClass_Engineer:
        {
            switch (tf2slot)
            {
                case 5:
                    return 3;
                case 6:
                    return 4;
                default:
                    return tf2slot;
            }
        }
        case TFClass_Spy:
        {
            switch (tf2slot)
            {
                case 1:
                    return 0;
                case 2:
                    return 2;
                case 4:
                    return 1;
                case 5:
                    return 3;
                case 6:
                    return 4;
                default:
                    return tf2slot;
            }
        }
        default:
        {
            switch (tf2slot)
            {
                case 5:
                    return 3;
                case 6:
                    return 4;
                default:
                    return tf2slot;
            }
        }
    }
}

// Inventory methodmap -> TF2
// Cosmetics must still be handled separately - they are always 8.
int LoadoutToTF2(int inventoryslot, any class)
{
    switch (class)
    {
        case TFClass_Engineer:
        {
            switch (inventoryslot)
            {
                case 3:
                    return 5;
                case 4:
                    return 6;
                default:
                    return inventoryslot;
            }
        }
        case TFClass_Spy:
        {
            switch (inventoryslot)
            {
                case 0:
                    return 1;
                case 1:
                    return 4;
                case 2:
                    return 2;
                case 3:
                    return 5;
                case 4:
                    return 6;
                default:
                    return inventoryslot;
            }
        }
        default:
        {
            switch (inventoryslot)
            {
                case 3:
                    return 5;
                case 4:
                    return 6;
                default:
                    return inventoryslot;
            }
        }
    }
}

//////////////////////////////////////////////////////////////////////////////
// DEFINITION                                                               //
//////////////////////////////////////////////////////////////////////////////

#define WEAPONS_LENGTH              5
#define COSMETICS_LENGTH            3

// An individiual definition for an item definition index, for modifying its loadout status.
// This is used for raw definition modifications.
enum struct definition_t
{
    // Definition name per config.
    char m_szName[NAME_LENGTH];

    // Used to identify this definition.
    int m_iItemDef;

    // Data used to modify this definition.
    int m_ClassInformation[view_as<int>(TFClass_Engineer) + 1]; // two-dimensional enum structs still aren't possible, at least with a stable version of sourcepawn, so i'm doing a hack instead
    char m_szClassName[ENTITY_NAME_LENGTH];
    char m_szCWXUID[NAME_LENGTH];
    bool m_bDefault;                                            // Set by config.
    bool m_bActualDefault;                                      // Decided by this plugin.
    bool m_bShowInLoadout;                                      // Set by config or basic item filtering sequence.
    int m_iAllowedInMedieval;                                   // 1 - allowed, 0 - not allowed, -1 - default to usual behaviour

    // Used to factor whether this is written to loaded config file.
    bool m_bSave;

    // Was this definition automatically configured by this plugin, rather than it being listed in a user's config file?
    bool m_bAutomaticallyConfigured;

    // Push to the g_Definitions StringMap.
    void PushToArray()
    {
        g_Definitions.SetArray(this.m_szName, this, sizeof(definition_t));
    }

    // Remove itself from the g_Definitions StringMap.
    void Delete()
    {
        g_Definitions.Remove(this.m_szName);
    }

    // Configure whether this is allowed for a specific slot on a specific class.
    void SetSlot(TFClassType class, int slot, bool enabled)
    {
        if (enabled)
            this.m_ClassInformation[view_as<int>(class)] |= (1 << slot);
        else
            this.m_ClassInformation[view_as<int>(class)] &= ~(1 << slot);
    }

    // Get whether this is allowed for a specific slot on a specific class.
    bool GetSlot(TFClassType class, int slot)
    {
        return !!(this.m_ClassInformation[view_as<int>(class)] & (1 << slot));
    }

    // Is this weapon/wearable allowed on a class?
    bool AllowedOnClass(TFClassType class)
    {
        return !!(this.m_ClassInformation[view_as<int>(class)]);
    }
}

static void CreateDefinition(definition_t def, char szName[NAME_LENGTH], int iItemDef = -1)
{
    // Store primary data.
    def.m_szName = szName;
    def.m_iItemDef = iItemDef;
}

static bool FindDefinition(definition_t def, char szName[NAME_LENGTH], int itemdef = TF_ITEMDEF_DEFAULT)
{
    if (g_Definitions.GetArray(szName, def, sizeof(definition_t)))
        return true;
    
    if (itemdef == TF_ITEMDEF_DEFAULT)
        itemdef = RetrieveItemDefByName(szName);
    if (itemdef != TF_ITEMDEF_DEFAULT)
    {
        if (g_DefinitionsByIndex[itemdef].m_bToggled && g_DefinitionsByIndex[itemdef].m_Object != NULL_DEFINITION)
        {
            view_as<Definition>(g_DefinitionsByIndex[itemdef].m_Object).Get(def);
            return true;
        }
    }
    return false;
}

// Not exactly the same as FindDefinition().
// If szName's item definition index can be retrieved, this will only check if the by-index definition is toggled,
// not if it has actually been filled yet.
static bool DefinitionExists(char szName[NAME_LENGTH], int itemdef = TF_ITEMDEF_DEFAULT)
{
    definition_t def;
    if (g_Definitions.GetArray(szName, def, sizeof(definition_t)))
        return true;
    
    if (itemdef != TF_ITEMDEF_DEFAULT)
        itemdef = RetrieveItemDefByName(szName);
    if (itemdef != TF_ITEMDEF_DEFAULT)
    {
        if (g_DefinitionsByIndex[itemdef].m_bToggled)
            return true;
    }
    return false;
}

//////////////////////////////////////////////////////////////////////////////
// DEFINITION METHODMAP                                                     //
//////////////////////////////////////////////////////////////////////////////

// A small methodmap that can be translated into a definition_t enum struct.
// Used with loadout managing code (as it can be either NULL or a legitimate definition).
methodmap Definition
{
    // Constructor.
    public Definition(int index)
    {
        return view_as<Definition>(index);
    }

    // The index of this definition.
    property int m_iIndex
    {
        public get() { return view_as<int>(this); }
    }

    // Get the definition_t enum struct associated with this definition.
    public bool Get(definition_t def)
    {
        if (this == NULL_DEFINITION)
        {
            def.m_iItemDef = -1;
            return false;
        }
        char key[NAME_LENGTH];
        g_DefinitionsSnapshot.GetKey(this.m_iIndex, key, sizeof(key));
        return g_Definitions.GetArray(key, def, sizeof(def));
    }

    // Iterator - start.
    public static Definition begin()
    {
        return view_as<Definition>(0);
    }

    // Iterator - end.
    public static Definition end()
    {
        return view_as<Definition>(g_DefinitionsSnapshot.Length);
    }

    // Retrieve from item definition index.
    public static Definition FromItemDefinitionIndex(int itemdef)
    {
        if (!g_DefinitionsByIndex[itemdef].m_bToggled)
            return NULL_DEFINITION;
        return view_as<Definition>(g_DefinitionsByIndex[itemdef].m_Object);
    }
}

// Attempt to resolve a Definition methodmap by name.
// Future notice: AVOID USING THIS IN MAINSTREAM CODE! ONLY USE IT IN NATIVES!
static Definition ResolveDefinitionByName(char szName[NAME_LENGTH])
{
    // Try to find it by item definition index.
    int itemdef = CalculateItemDefFromSectionName(szName);
    if (itemdef != TF_ITEMDEF_DEFAULT)
    {
        Definition definition = Definition.FromItemDefinitionIndex(itemdef);
        if (definition != NULL_DEFINITION)
            return definition;
    }

    // Walk through each definition, obtain its enum struct and see if the names match.
    for (Definition it = Definition.begin(); it != Definition.end(); ++it)
    {
        definition_t def;
        it.Get(def);
        if (strcmp(def.m_szName, szName) == 0)
            return it;
    }

    // Return NULL_DEFINITION.
    return NULL_DEFINITION;
}

//////////////////////////////////////////////////////////////////////////////
// LOADOUT                                                                  //
//////////////////////////////////////////////////////////////////////////////

enum struct slot_t
{
    // Chosen from the loadout menu.
    Definition m_Selected;
    
    // Inhibited weapon.
    Definition m_Inhibited;

    // Cached fields.
    Definition m_Cached;
    int m_hReplacement;
    int m_hFakeSlotReplacement;
    int m_iCachedItemDefinitionIndex;

    // Cached runtime attributes.
    int runtime_attributes[20];
    float runtime_attributes_values[20];
    int runtime_attributes_count;

    // Cached static attributes.
    int static_attributes[16];
    float static_attributes_values[16];
    int static_attributes_count;

    // Cached SOC attributes.
    int soc_attributes[16];
    float soc_attributes_values[16];
    int soc_attributes_count;

    // Other cached weapon data.
    int m_iItemIDHigh;
    int m_iItemIDLow;
    int m_iEntityLevel;
    int m_iEntityQuality;
    int m_eStrangeType;
    int m_eStatTrakModuleType;

    // Is this slot temporary?
    bool m_bTemporary;
}
slot_t g_SlotData[MAXPLAYERS + 1][view_as<int>(TFClass_Engineer) + 1][WEAPONS_LENGTH + COSMETICS_LENGTH];

enum struct player_t
{
    // Chosen from the loadout menu.
    int m_iLoadoutSlot;

    // Cached fields.
    int m_ToEquip[WEAPONS_LENGTH + COSMETICS_LENGTH];
    int m_ToEquipLast[(WEAPONS_LENGTH + COSMETICS_LENGTH) * 2];
    int m_iEquipIndex;
    int m_iLastEquipIndex;
    int m_iSlotToEquip;
    TFClassType m_eLastClass;

    // Miscellaneous
    bool m_bSpawning;
    bool m_bFirstTime;
    bool m_bDoNotSetSpawning;
    bool m_bForceRegeneration;
}
player_t g_PlayerData[MAXPLAYERS + 1];

methodmap Slot
{
    // Constructor.
    public Slot(int player, int class, int index)
    {
        if (0 > player || player > MaxClients || !IsClientInGame(player))
            return view_as<Slot>(-1);
        return view_as<Slot>(player | ((class & 0xFF) << 8) | ((index & 0xFF) << 16));
    }

    // The raw value of this object.
    property any m_Value
    {
        public get() { return view_as<any>(this); }
    }

    // The player index.
    property int entindex
    {
        public get() { return view_as<int>(this) & 0xFF; }
    }

    // The designated class of the player at the time of manipulating this slot.
    property any m_eClass
    {
        public get() { return (this.m_Value >> 8) & 0xFF; }
    }

    // The slot index within the Inventory object.
    property any m_iSlotIndex
    {
        public get() { return (this.m_Value >> 16) & 0xFF; }
    }

    // Selected definition.
    property Definition m_Selected
    {
        public get() { return g_SlotData[this.entindex][this.m_eClass][this.m_iSlotIndex].m_Selected; }
        public set(Definition value) { g_SlotData[this.entindex][this.m_eClass][this.m_iSlotIndex].m_Selected = value; }
    }

    // Inhibited definition.
    property Definition m_Inhibited
    {
        public get() { return g_SlotData[this.entindex][this.m_eClass][this.m_iSlotIndex].m_Inhibited; }
        public set(Definition value) { g_SlotData[this.entindex][this.m_eClass][this.m_iSlotIndex].m_Inhibited = value; }
    }

    // Prioritised definition.
    property Definition m_Prioritised
    {
        public get()
        {
            if (this.m_Selected != NULL_DEFINITION)
                return this.m_Selected;
            else if (this.m_Inhibited != NULL_DEFINITION)
                return this.m_Inhibited;
            return NULL_DEFINITION;
        }
    }

    // Current (cached) definition.
    property Definition m_Cached
    {
        public get() { return g_SlotData[this.entindex][this.m_eClass][this.m_iSlotIndex].m_Cached; }
        public set(Definition value) { g_SlotData[this.entindex][this.m_eClass][this.m_iSlotIndex].m_Cached = value; }
    }

    // Default definition for this slot.
    property Definition m_Default
    {
        public get() { return g_DefaultDefinitions[this.m_eClass][this.m_iSlotIndex]; }
    }

    // Get the replacement entity.
    property int m_hReplacement
    {
        public get() { return g_SlotData[this.entindex][this.m_eClass][this.m_iSlotIndex].m_hReplacement; }
        public set(int value) { g_SlotData[this.entindex][this.m_eClass][this.m_iSlotIndex].m_hReplacement = value; } 
    }

    // Get the fake replacement entity. This is used for weapons in custom slots.
    property int m_hFakeSlotReplacement
    {
        public get() { return g_SlotData[this.entindex][this.m_eClass][this.m_iSlotIndex].m_hFakeSlotReplacement; }
        public set(int value) { g_SlotData[this.entindex][this.m_eClass][this.m_iSlotIndex].m_hFakeSlotReplacement = value; } 
    }

    // Get the cached item definition index.
    property int m_iCachedItemDefinitionIndex
    {
        public get() { return g_SlotData[this.entindex][this.m_eClass][this.m_iSlotIndex].m_iCachedItemDefinitionIndex; }
        public set(int value) { g_SlotData[this.entindex][this.m_eClass][this.m_iSlotIndex].m_iCachedItemDefinitionIndex = value; } 
    }

    // Get the cached high DWORD of the item ID.
    property int m_iItemIDHigh
    {
        public get() { return g_SlotData[this.entindex][this.m_eClass][this.m_iSlotIndex].m_iItemIDHigh; }
        public set(int value) { g_SlotData[this.entindex][this.m_eClass][this.m_iSlotIndex].m_iItemIDHigh = value; } 
    }

    // Get the cached low DWORD of the item ID.
    property int m_iItemIDLow
    {
        public get() { return g_SlotData[this.entindex][this.m_eClass][this.m_iSlotIndex].m_iItemIDLow; }
        public set(int value) { g_SlotData[this.entindex][this.m_eClass][this.m_iSlotIndex].m_iItemIDLow = value; } 
    }

    // Get entity level.
    property int m_iEntityLevel
    {
        public get() { return g_SlotData[this.entindex][this.m_eClass][this.m_iSlotIndex].m_iEntityLevel; }
        public set(int value) { g_SlotData[this.entindex][this.m_eClass][this.m_iSlotIndex].m_iEntityLevel = value; } 
    }

    // Get entity quality.
    property int m_iEntityQuality
    {
        public get() { return g_SlotData[this.entindex][this.m_eClass][this.m_iSlotIndex].m_iEntityQuality; }
        public set(int value) { g_SlotData[this.entindex][this.m_eClass][this.m_iSlotIndex].m_iEntityQuality = value; } 
    }

    // Get strange type.
    property int m_eStrangeType
    {
        public get() { return g_SlotData[this.entindex][this.m_eClass][this.m_iSlotIndex].m_eStrangeType; }
        public set(int value) { g_SlotData[this.entindex][this.m_eClass][this.m_iSlotIndex].m_eStrangeType = value; } 
    }

    // Get stattrak type.
    property int m_eStatTrakModuleType
    {
        public get() { return g_SlotData[this.entindex][this.m_eClass][this.m_iSlotIndex].m_eStatTrakModuleType; }
        public set(int value) { g_SlotData[this.entindex][this.m_eClass][this.m_iSlotIndex].m_eStatTrakModuleType = value; } 
    }

    // Is this slot temporary?
    property bool m_bTemporary
    {
        public get() { return g_SlotData[this.entindex][this.m_eClass][this.m_iSlotIndex].m_bTemporary; }
        public set(bool value) { g_SlotData[this.entindex][this.m_eClass][this.m_iSlotIndex].m_bTemporary = value; } 
    }

    // Get the weapon for this slot.
    public int GetWeapon(any& iswearable = 0, bool aliveonly = false)
    {
        // Check if it is in CTFPlayer::m_hMyWeapons.
        int weapon = INVALID_ENT_REFERENCE;
        for (int index = 0; index < MAX_WEAPONS; ++index)
        {
            // Get the weapon.
            weapon = GetEntPropEnt(this.entindex, Prop_Send, "m_hMyWeapons", index);
            if (weapon == INVALID_ENT_REFERENCE)
                continue;

            // Check if the weapon is about to be removed.
            if (aliveonly && GetEntityFlags(weapon) & FL_KILLME)
                continue;

            // Skip if this is this slot's fake slot replacement weapon.
            if (EntIndexToEntRef(weapon) == this.m_hFakeSlotReplacement)
                continue;

            // Check if the slots match.
            if (GetItemLoadoutSlotOfWeapon(weapon, this.m_eClass) == LoadoutToTF2(this.m_iSlotIndex, this.m_eClass))
            {
                iswearable = false;
                return weapon;
            }
        }

        // We will have to walk through CTFPlayer::m_hMyWearables to see if it is a wearable.
        any m_hMyWearables = view_as<any>(GetEntityAddress(this.entindex)) + FindSendPropInfo("CTFPlayer", "m_hMyWearables");
        for (int index = 0, size = LoadFromAddress(m_hMyWearables + CUtlVector_m_Size, NumberType_Int32); index < size; ++index)
        {
            // Get the wearable.
            int handle = LoadFromAddress(LoadFromAddress(m_hMyWearables, NumberType_Int32) + index * 4, NumberType_Int32);
            weapon = EntRefToEntIndex(handle | (1 << 31));
            if (weapon == INVALID_ENT_REFERENCE)
                continue;

            // Check if the wearable is about to be removed.
            if (aliveonly && GetEntityFlags(weapon) & FL_KILLME)
                continue;

            // Check if the slots match.
            if (GetItemLoadoutSlotOfWeapon(weapon, this.m_eClass) == LoadoutToTF2(this.m_iSlotIndex, this.m_eClass))
            {
                iswearable = true;
                return weapon;
            }
        }

        // Fall back to checking if there is a replacement entity being used.
        // I really don't like this, but it's necessary considering the delay for equipping weapons.
        if (IsValidEntity(this.m_hReplacement))
            return EntRefToEntIndex(this.m_hReplacement);

        // Non-existent?
        return INVALID_ENT_REFERENCE;
    }

    // Remove the weapon from this slot.
    public void RemoveWeapon()
    {
        bool iswearable;
        int weapon = this.GetWeapon(iswearable, true);
        while (IsValidEntity(weapon) && !(GetEntityFlags(weapon) & FL_KILLME))
        {
            if (iswearable)
                TF2_RemoveWearable(this.entindex, weapon);
            else
            {
                TF2_RemoveWeapon(this.entindex, weapon);
                if (EntIndexToEntRef(weapon) == this.m_hReplacement && IsValidEntity(this.m_hFakeSlotReplacement))
                    TF2_RemoveWeapon(this.entindex, this.m_hFakeSlotReplacement);
            }
            weapon = this.GetWeapon(iswearable, true);
        }
    }

    // Retrieve cached runtime attributes.
    public int GetRuntimeAttributes(int attributes[20], float attributes_values[20])
	{
		attributes = g_SlotData[this.entindex][this.m_eClass][this.m_iSlotIndex].runtime_attributes;
		attributes_values = g_SlotData[this.entindex][this.m_eClass][this.m_iSlotIndex].runtime_attributes_values;
		return g_SlotData[this.entindex][this.m_eClass][this.m_iSlotIndex].runtime_attributes_count;
	}

    // Cache runtime attributes.
	public void SetRuntimeAttributes(int attributes[20], float attributes_values[20], int count)
	{
		g_SlotData[this.entindex][this.m_eClass][this.m_iSlotIndex].runtime_attributes = attributes;
		g_SlotData[this.entindex][this.m_eClass][this.m_iSlotIndex].runtime_attributes_values = attributes_values;
		g_SlotData[this.entindex][this.m_eClass][this.m_iSlotIndex].runtime_attributes_count = count;
	}

    // Retrieve cached static attributes.
    public int GetStaticAttributes(int attributes[16], float attributes_values[16])
	{
		attributes = g_SlotData[this.entindex][this.m_eClass][this.m_iSlotIndex].static_attributes;
		attributes_values = g_SlotData[this.entindex][this.m_eClass][this.m_iSlotIndex].static_attributes_values;
		return g_SlotData[this.entindex][this.m_eClass][this.m_iSlotIndex].static_attributes_count;
	}

    // Cache static attributes.
	public void SetStaticAttributes(int attributes[16], float attributes_values[16], int count)
	{
		g_SlotData[this.entindex][this.m_eClass][this.m_iSlotIndex].static_attributes = attributes;
		g_SlotData[this.entindex][this.m_eClass][this.m_iSlotIndex].static_attributes_values = attributes_values;
		g_SlotData[this.entindex][this.m_eClass][this.m_iSlotIndex].static_attributes_count = count;
	}

	// Retrieve cached SOC attributes.
    public int GetSOCAttributes(int attributes[16], float attributes_values[16])
	{
		attributes = g_SlotData[this.entindex][this.m_eClass][this.m_iSlotIndex].soc_attributes;
		attributes_values = g_SlotData[this.entindex][this.m_eClass][this.m_iSlotIndex].soc_attributes_values;
		return g_SlotData[this.entindex][this.m_eClass][this.m_iSlotIndex].soc_attributes_count;
	}

    // Cache SOC attributes.
	public void SetSOCAttributes(int attributes[16], float attributes_values[16], int count)
	{
		g_SlotData[this.entindex][this.m_eClass][this.m_iSlotIndex].soc_attributes = attributes;
		g_SlotData[this.entindex][this.m_eClass][this.m_iSlotIndex].soc_attributes_values = attributes_values;
		g_SlotData[this.entindex][this.m_eClass][this.m_iSlotIndex].soc_attributes_count = count;
	}

    // Cache information about the currently loaded weapon.
    public void CacheWeaponInformation()
    {
        // Get the current weapon.
        int weapon = this.GetWeapon(.aliveonly = true);
        int itemdef = GetEntProp(weapon, Prop_Send, "m_iItemDefinitionIndex");

        // Cache this weapon's runtime attributes.
        int attributes[20];
        float attributes_values[20];
        int size = TF2Attrib_ListDefIndices(weapon, attributes);
        if (size == -1)
            ThrowError("[Weapon Manager]: ERROR: FAILED TO RETRIEVE RUNTIME ATTRIBUTES FOR ITEM DEF %i!", itemdef);
        for (int attrib = 0; attrib < size; ++attrib)
        {
            any attribute = TF2Attrib_GetByDefIndex(weapon, attributes[attrib]);
            if (!attribute)
                ThrowError("[Weapon Manager]: ADDRESS FOR ATTRIBUTE %u IS NULL (ITEM DEF %i)", attribute, itemdef);
            attributes_values[attrib] = TF2Attrib_GetValue(attribute);
        }
        this.SetRuntimeAttributes(attributes, attributes_values, size);

        // Cache this weapon's static attributes.
        int static_attributes[16];
        float static_attributes_values[16];
        size = TF2Attrib_GetStaticAttribs(itemdef, static_attributes, static_attributes_values);
        if (size == -1)
            ThrowError("[Weapon Manager]: ERROR: FAILED TO RETRIEVE STATIC ATTRIBUTES FOR ITEM DEF %i!", itemdef);
        this.SetStaticAttributes(static_attributes, static_attributes_values, size);

        // Cache this weapon's SOC attributes.
        size = TF2Attrib_GetSOCAttribs(weapon, static_attributes, static_attributes_values);
        if (size == -1)
            ThrowError("[Weapon Manager]: ERROR: FAILED TO RETRIEVE SOC ATTRIBUTES FOR ITEM DEF %i!", itemdef);
        this.SetSOCAttributes(static_attributes, static_attributes_values, size);

        // Cache this weapon's item ID.
        this.m_iItemIDHigh = GetEntProp(weapon, Prop_Send, "m_iItemIDHigh");
        this.m_iItemIDLow = GetEntProp(weapon, Prop_Send, "m_iItemIDLow");

        // Cache this weapon's entity level/quality.
        this.m_iEntityLevel = GetEntProp(weapon, Prop_Send, "m_iEntityLevel");
        this.m_iEntityQuality = GetEntProp(weapon, Prop_Send, "m_iEntityQuality");

        // Cache this weapon's strange information.
        this.m_eStrangeType = GetEntData(weapon, CTFWeaponBase_m_eStrangeType);
        this.m_eStatTrakModuleType = GetEntData(weapon, CTFWeaponBase_m_eStatTrakModuleType);
    }

    // Handle equipping a new weapon altogether for this slot.
    public bool CreateNewWeapon(bool& iswearable, bool& correctSlot, int& entity, int& ammotype, char classname[ENTITY_NAME_LENGTH])
    {
        // Re-calculate basic information.
        int tf2Slot = LoadoutToTF2(this.m_iSlotIndex, this.m_eClass);
        char uid[NAME_LENGTH];
        bool hascwxWeapon = ((g_LoadedCWX && this.m_iSlotIndex < WEAPONS_LENGTH) ? CWX_GetPlayerLoadoutItem(this.entindex, this.m_eClass, tf2Slot, uid, sizeof(uid), LOADOUT_FLAG_UPDATE_BACKEND) : false);

        // Get the definition for this slot.
        definition_t def;
        this.m_Prioritised.Get(def);

        // Check if this slot is CWX. 
        if (strlen(def.m_szCWXUID) > 0)
        {
            // Ensure the desired weapon is equipped on CWX's side.
            if (!hascwxWeapon || (strlen(uid) > 0 && strcmp(uid, def.m_szCWXUID) != 0))
                CWX_SetPlayerLoadoutItem(this.entindex, this.m_eClass, def.m_szCWXUID, LOADOUT_FLAG_UPDATE_BACKEND);

            // Continue.
            return false;
        }
        else if (hascwxWeapon)
            CWX_RemovePlayerLoadoutItem(this.entindex, this.m_eClass, tf2Slot, LOADOUT_FLAG_UPDATE_BACKEND);

        // If the fake replacement entity is valid, destroy it.
        if (IsValidEntity(this.m_hFakeSlotReplacement))
            TF2_RemoveWeapon(this.entindex, this.m_hFakeSlotReplacement);

        // Remove the weapon that is already equipped.
        if (this.m_iSlotIndex < WEAPONS_LENGTH)
        {
            // Obscure bug: if you have multiple custom weapons equipped and you equip a new weapon through
            // the !loadout menu, it may not be equippable until you switch classes.
            //
            // To get around this, temporarily unequip any weapon that has a fake slot entity.
            for (int i2 = 0; i2 < MAX_WEAPONS; ++i2)
            {
                // Walk through each weapon.
                int weapon = GetEntPropEnt(this.entindex, Prop_Send, "m_hMyWeapons", i2);
                if (!IsValidEntity(weapon))
                    continue;

                // Verify slot information.
                if (IsValidEntity(g_EntityData[weapon].m_hFakeSlotReference))
                {
                    SetEntPropEnt(this.entindex, Prop_Send, "m_hMyWeapons", INVALID_ENT_REFERENCE, i2);
                    g_PlayerData[this.entindex].m_ToEquipLast[g_PlayerData[this.entindex].m_iLastEquipIndex++] = EntIndexToEntRef(weapon);
                }
            }

            // Remove the weapon associated with this slot.
            this.RemoveWeapon();
        }
        else if (this.m_iSlotIndex >= WEAPONS_LENGTH)
            ThrowError("[Weapon Manager]: Sorry, but cosmetic code is currently not supported!");

        // Translate the classname for the desired class.
        strcopy(classname, sizeof(classname), def.m_szClassName);
        TranslateWeaponEntForClass(classname, sizeof(classname), this.m_eClass);

        // Start creating our desired weapon/wearable by stealing m_Item from a decoy entity.
        entity = CreateEntityByName(classname);
        SetEntData(entity, FindSendPropInfo("CEconEntity", "m_iEntityQuality"), AE_UNIQUE);
        SetEntProp(entity, Prop_Send, "m_iItemDefinitionIndex", def.m_iItemDef);
        SetEntProp(entity, Prop_Send, "m_iAccountID", GetSteamAccountID(this.entindex));
        SetEntProp(entity, Prop_Send, "m_bInitialized", true);
        DispatchSpawn(entity);

        // Now grab m_Item from it and delete the entity.
        // RemoveEntity() does not delete entities immediately, so we don't have to worry
        // about the m_Item object being free()'d.
        Address m_Item = GetEntityAddress(entity) + view_as<Address>(FindSendPropInfo("CEconEntity", "m_Item"));
        RemoveEntity(entity);

        // Call CTFPlayer::GiveNamedItem() to finalize weapon/wearable creation.
        // The reason we do this is not only is this meant to be the official method of
        // actually creating weapons, but it also triggers TF2Items' OnGiveNamedItem()
        // forward. Yes, I could use SM-Memory, but I'm trying not to.
        entity = SDKCall(SDKCall_CTFPlayer_GiveNamedItem, this.entindex, classname, 0, m_Item, true);
        SetEntPropEnt(entity, Prop_Send, "m_hOwnerEntity", this.entindex);
        SetEntProp(entity, Prop_Send, "m_iTeamNum", GetEntProp(this.entindex, Prop_Send, "m_iTeamNum"));
        SetEntProp(entity, Prop_Send, "m_bValidatedAttachedEntity", true); // fuck you

        // Work out whether the slot for this weapon is correct.
        correctSlot = (TF2Econ_GetItemLoadoutSlot(def.m_iItemDef, this.m_eClass) == tf2Slot);
        if (!correctSlot)
        {
            // ...By item definition, the slot is correct. However, if the entity classname
            // is modified, it may be using a weapon type that is NOT for the designated slot.
            // Walk through each base weapon and find one with matching classnames and then
            // check if the slot is correct using that base weapon's item definition index.
            //
            // 01:02: Dude I swear to god this plugin has like 1439314 fucking bugs and I
            // am fucking losing it at the minute. This plugin requires so much cognitive
            // thinking.
            //
            // 01:04: Wires.
            for (int item, length = g_StockItems.Length; item < length; ++item)
            {
                int foundItemDef = g_StockItems.Get(item);
                char foundClassName[64];
                TF2Econ_GetItemClassName(foundItemDef, foundClassName, sizeof(foundClassName));
                TranslateWeaponEntForClass(foundClassName, sizeof(foundClassName), this.m_eClass);
                if (strcmp(foundClassName, classname) == 0)
                {
                    correctSlot = (TF2Econ_GetItemDefaultLoadoutSlot(foundItemDef) == tf2Slot);
                    if (correctSlot)
                        break;
                }
            }
        }

        // If this weapon is in a custom slot (more on that below...), it will have to
        // use a completely new ammo type.
        iswearable = (StrContains(def.m_szClassName, "tf_wearable") == 0);
        ammotype = 0;
        if (!iswearable)
        {
            ammotype = GetEntProp(entity, Prop_Send, "m_iPrimaryAmmoType");
            if (!correctSlot && TF_AMMO_PRIMARY <= ammotype < TF_AMMO_COUNT)
            {
                g_EntityData[entity].m_iPrimaryAmmoType = ammotype;
                SetEntProp(entity, Prop_Send, "m_iPrimaryAmmoType", UNUSED_SLOT + this.m_iSlotIndex);
            }
        }

        // If this is an inhibited weapon, write any cached data to the new weapon's m_Item.
        if (this.m_Prioritised == this.m_Inhibited)
        {
            // Copy over the weapon's item ID.
            SetEntProp(entity, Prop_Send, "m_iItemIDHigh", this.m_iItemIDHigh);
            SetEntProp(entity, Prop_Send, "m_iItemIDLow", this.m_iItemIDLow);
            SetEntData(entity, CEconEntity_m_iItemID, this.m_iItemIDHigh);
            SetEntData(entity, CEconEntity_m_iItemID + 4, this.m_iItemIDLow);

            // Copy over entity quality/level data.
            SetEntProp(entity, Prop_Send, "m_iEntityLevel", this.m_iEntityLevel);
            SetEntData(entity, FindSendPropInfo("CEconEntity", "m_iEntityQuality"), this.m_iEntityQuality);

            // Set the cached runtime attributes.
            int attributes[20];
            float attributes_values[20];
            for (int attrib = 0, size = this.GetRuntimeAttributes(attributes, attributes_values); attrib < size; ++attrib)
                TF2Attrib_SetByDefIndex(entity, attributes[attrib], attributes_values[attrib]);

            // TODO in the future: look at strange weapons?
        }

        // If this weapon is allowed in medieval mode, set its attribute.
        if (def.m_iAllowedInMedieval == 1)
            TF2Attrib_SetByName(entity, "allowed in medieval mode", 1.00);

        // Set m_hReplacement to this entity and set entity information.
        this.m_hReplacement = EntIndexToEntRef(entity);
        g_EntityData[entity].slot = tf2Slot;

        // If this is the Gas Passer, do not immediately grant ammo.
        // However this must be done the next frame.
        RequestFrame(FixAmmo, this);

        // Return true to signal that we created the weapon, not CWX.
        return true;
    }

    public bool CreateFakeSlotReplacement(int entity, int ammotype, char classname[ENTITY_NAME_LENGTH])
    {
        // Re-calculate basic information.
        int tf2Slot = LoadoutToTF2(this.m_iSlotIndex, this.m_eClass);

        // Get the definition for this slot.
        definition_t def;
        this.m_Prioritised.Get(def);

        // Come up with a classname for the fake slot replacement entity.
        int foundItemDef = TF_ITEMDEF_DEFAULT;
        if (this.m_eClass != TFClass_Engineer && this.m_eClass != TFClass_Spy && this.m_iSlotIndex == 3)
            foundItemDef = 25;
        else if (this.m_eClass != TFClass_Engineer && this.m_eClass != TFClass_Spy && this.m_iSlotIndex  == 4)
            foundItemDef = 26;
        else
        {
            for (int item, length = g_StockItems.Length; item < length; ++item)
            {
                foundItemDef = g_StockItems.Get(item);
                int foundSlot = TF2ToLoadout(TF2Econ_GetItemLoadoutSlot(foundItemDef, this.m_eClass), this.m_eClass);
                if (foundSlot == this.m_iSlotIndex )
                    break;
            }
        }

        // Set the classname for the fake slot replacement entity.
        TF2Econ_GetItemClassName(foundItemDef, classname, sizeof(classname));
        TranslateWeaponEntForClass(classname, sizeof(classname), this.m_eClass);

        // Create the fake slot replacement entity.
        int replacement = entity;
        entity = CreateEntityByName(classname);
        SetEntData(entity, FindSendPropInfo("CEconEntity", "m_iEntityQuality"), AE_UNIQUE);
        SetEntPropEnt(entity, Prop_Send, "m_hOwnerEntity", this.entindex);
        SetEntProp(entity, Prop_Send, "m_iItemDefinitionIndex", def.m_iItemDef);
        SetEntProp(entity, Prop_Send, "m_iAccountID", GetSteamAccountID(this.entindex));
        SetEntProp(entity, Prop_Send, "m_iTeamNum", GetEntProp(this.entindex, Prop_Send, "m_iTeamNum"));
        SetEntProp(entity, Prop_Send, "m_bValidatedAttachedEntity", true); // fuck you
        SetEntProp(entity, Prop_Send, "m_bOnlyIterateItemViewAttributes", true);
        SetEntProp(entity, Prop_Send, "m_bInitialized", true);
        DispatchSpawn(entity);

        // If this weapon is allowed in medieval mode, set its attribute.
        if (def.m_iAllowedInMedieval == 1)
            TF2Attrib_SetByName(entity, "allowed in medieval mode", 1.00);

        // Equip the fake slot replacement entity.
        if (TF_AMMO_PRIMARY <= ammotype < TF_AMMO_COUNT)
        {
            SetEntProp(entity, Prop_Send, "m_iPrimaryAmmoType", UNUSED_SLOT + WEAPONS_LENGTH + this.m_iSlotIndex );
            SetEntProp(this.entindex, Prop_Send, "m_iAmmo", 2, UNUSED_SLOT + WEAPONS_LENGTH + this.m_iSlotIndex );
        }
        EquipPlayerWeapon(this.entindex, entity);
        this.m_hFakeSlotReplacement = EntIndexToEntRef(entity);
        g_EntityData[entity].slot = tf2Slot;
        g_EntityData[replacement].m_hFakeSlotReference = this.m_hFakeSlotReplacement;
        g_PlayerData[this.entindex].m_iSlotToEquip = this.m_iSlotIndex;
    }
}

// Primary - 0
// Secondary - 1
// Melee - 2
// Disguise Kit - 3
// Watch - 4
// Construction PDA - 3
// Destruction PDA - 4
// Cosmetics - 5 to 7
methodmap Inventory
{
    // Constructor.
	public Inventory(int player, any class = -1)
	{
		if (0 > player || player > MaxClients || !IsClientInGame(player))
			return view_as<Inventory>(-1);
		return view_as<Inventory>(player | ((class & 0xFF) << 8));
	}

    // The raw value of this object.
	property any m_Value
	{
		public get() { return view_as<any>(this); }
	}

    // The player index.
	property int entindex
	{
		public get() { return view_as<int>(this) & 0xFF; }
	}

	// The class that this inventory is currently using.
	property any m_eClass
	{
		public get()
		{
			int class = (this.m_Value >> 8) & 0xFF;
			return ((class == 0xFF) ? view_as<int>(TF2_GetPlayerClass(this.entindex)) : class); 
		}
	}

    // Get a slot.
	public Slot GetSlot(int index)
	{
		return Slot(this.entindex, this.m_eClass, index);
	}

	// Get a weapon slot from index.
	public Slot GetWeaponSlot(int index)
	{
		return Slot(this.entindex, this.m_eClass, index);
	}

	// Get a cosmetic slot from index.
	public Slot GetCosmeticSlot(int index)
	{
		return Slot(this.entindex, this.m_eClass, index + WEAPONS_LENGTH);
	}

    // Clear this record.
	public void Clear()
    {
        for (int i = 0; i < WEAPONS_LENGTH + COSMETICS_LENGTH; ++i)
        {
            Slot slot = this.GetSlot(i);
            slot.m_Inhibited = NULL_DEFINITION;
            slot.m_Selected = NULL_DEFINITION;
            slot.m_Cached = NULL_DEFINITION;
            slot.m_hReplacement = INVALID_ENT_REFERENCE;
            slot.m_hFakeSlotReplacement = INVALID_ENT_REFERENCE;
            slot.m_iCachedItemDefinitionIndex = TF_ITEMDEF_DEFAULT;
        }
        g_PlayerData[this.entindex].m_iSlotToEquip = -1;
    }

    // If any specific equipped weapon has an unmatching entity classname,
    // set it to its slot's m_Inhibited.
    public void CorrectWeapons()
    {
        for (int i = 0; i < WEAPONS_LENGTH; ++i)
        {
            // Check if we're working with a selected slot, to start of.
            Slot slot = this.GetWeaponSlot(i);
            definition_t selected;
            slot.m_Selected.Get(selected);
            if (slot.m_Selected != NULL_DEFINITION)
            {
                slot.m_Inhibited = NULL_DEFINITION;
                continue;
            }

            // Skip if this is a CWX weapon.
            char uid[NAME_LENGTH];
            bool hascwxWeapon = (g_LoadedCWX ? CWX_GetPlayerLoadoutItem(this.entindex, this.m_eClass, LoadoutToTF2(i, this.m_eClass), uid, sizeof(uid)) : false);
            if (hascwxWeapon)
                continue;

            // Get the registered weapon definition's entity classname.
            int current = slot.GetWeapon();
            if (!IsValidEntity(current))
                continue;
            char buffer[ENTITY_NAME_LENGTH];
            GetEntityClassname(current, buffer, sizeof(buffer));

            // Get the internal definition and check if it exists and can be applied to this weapon slot.
            int itemdef = ((slot.m_iCachedItemDefinitionIndex != TF_ITEMDEF_DEFAULT) ? slot.m_iCachedItemDefinitionIndex : GetEntProp(current, Prop_Send, "m_iItemDefinitionIndex"));
            Definition found = Definition.FromItemDefinitionIndex(itemdef);
            definition_t foundDef;
            found.Get(foundDef);
            if (found != NULL_DEFINITION && foundDef.GetSlot(this.m_eClass, LoadoutToTF2(i, this.m_eClass)))
            {
                // Get the definition's classname.
                char registeredBuffer[ENTITY_NAME_LENGTH];
                strcopy(registeredBuffer, sizeof(registeredBuffer), foundDef.m_szClassName);
                TranslateWeaponEntForClass(registeredBuffer, sizeof(registeredBuffer), this.m_eClass);

                // Get the inhibited definition
                definition_t inhibitedDef;
                slot.m_Inhibited.Get(inhibitedDef);

                // Compare the two classnames.
                if (strcmp(buffer, registeredBuffer) != 0)
                {
                    // Set m_Inhibited to the found definition.
                    slot.m_Inhibited = found;

                    // Cache all the attributes for this object.
                    slot.CacheWeaponInformation();
                }
                else if (inhibitedDef.m_iItemDef != foundDef.m_iItemDef)
                    slot.m_Inhibited = NULL_DEFINITION;
                continue;
            }

            // Well, we didn't find a definition for it. If we are not blocking unlisted definitions,
            // don't do anything from here.
            if (!g_bBlockUnlisted)
                continue;

            // This weapon is not available for this slot! Remove it.
            if (slot.m_Inhibited == NULL_DEFINITION)
            {
                slot.RemoveWeapon();

                // See if there is a replacement that we can use instead.
                slot.m_Inhibited = slot.m_Default;
            }
        }
    }

    // Construct this player's loadout.
    public void ConstructLoadout()
    {
        // Invoke the pre-construction forward.
        Action result;
        Call_StartForward(g_ConstructingLoadout);
        Call_PushCell(this.entindex);
        Call_PushCell(g_PlayerData[this.entindex].m_bSpawning);
        Call_Finish(result);
        g_PlayerData[this.entindex].m_bSpawning = false;

        // Block if the result is Action_Handled or Action_Stop.
        if (result == Plugin_Handled || result == Plugin_Stop)
            return;

        // Also set it to false next frame in rare scenarios.
        RequestFrame(ClientNoLongerSpawning, this.entindex);

        // Construct the new loadout.
        for (int i = 0; i < WEAPONS_LENGTH + COSMETICS_LENGTH; ++i)
        {
            // Check if this slot should be overrided.
            Slot econentity = this.GetSlot(i);
            bool selected = (econentity.m_Prioritised != NULL_DEFINITION);
            if (!selected)
                continue;

            // Check if the replacement entity is about to die.
            if (IsValidEntity(econentity.m_hReplacement) && !(GetEntityFlags(econentity.m_hReplacement) & FL_KILLME))
            {
                // If not, correct the ammo for the fake slot replacement.
                SetEntProp(this.entindex, Prop_Send, "m_iAmmo", 1, .element = MAX_AMMO_SLOTS - 1);
                continue;
            }

            // Get the definition for this slot.
            definition_t def;
            econentity.m_Prioritised.Get(def);

            // Create the desired entity.
            char classname[ENTITY_NAME_LENGTH];
            int entity, ammotype;
            bool iswearable, correctSlot;
            bool created = econentity.CreateNewWeapon(iswearable, correctSlot, entity, ammotype, classname); // yes, this looks INCREDIBLY lazy, but the code was originally here so :D
            if (!created)
                continue;

            // Equip the wearable or queue the weapon.
            if (iswearable)
            {
                // Before we do anything else, we actually have to set this to true so that
                // CTFPlayer::ValidateWearables() does not delete wearables spawned here!
                if (i < WEAPONS_LENGTH)
                    SetEntData(entity, CTFWearable_m_bAlwaysAllow, true, 1);
                
                // Spawn the wearable.
                SDKCall(SDKCall_CTFPlayer_EquipWearable, this.entindex, entity);
            }
            else
            {
                // Equipping weapons are delayed until the end of loadout construction.
                // This is because of an issue with equipping multiple custom slot weapons in 
                // one inventory, where one weapon may always be equipped regardless of the 
                // slot chosen.
                if (correctSlot)
                    g_PlayerData[this.entindex].m_ToEquip[g_PlayerData[this.entindex].m_iEquipIndex++] = entity;
                else
                    g_PlayerData[this.entindex].m_ToEquipLast[g_PlayerData[this.entindex].m_iLastEquipIndex++] = EntIndexToEntRef(entity);
            }

            // Continue if this is a wearable.
            if (iswearable)
                continue;

            // Time for some really stupid fucking stuff.
            // If this entity is a weapon and NOT designated for this slot, then we need to
            // create yet another fake entity. Great.
            if (correctSlot)
                continue;

            // Create a fake slot replacement entity and equip it.
            econentity.CreateFakeSlotReplacement(entity, ammotype, classname);
        }

        // If any weapons are cached, equip it here now.
        for (int i = 0; i < g_PlayerData[this.entindex].m_iEquipIndex; ++i)
            EquipPlayerWeapon(this.entindex, g_PlayerData[this.entindex].m_ToEquip[i]);
        ClearEquipLastBacklog(this.entindex);
        g_PlayerData[this.entindex].m_iEquipIndex = 0;

        // Call the post-construction forward.
        Call_StartForward(g_ConstructingLoadoutPost);
        Call_PushCell(this.entindex);
        Call_PushCell(g_PlayerData[this.entindex].m_bSpawning);
        Call_Finish(result);
    }

    // Cache the existing loadout.
    public void CacheCurrentLoadout()
    {
        for (int i = 0; i < WEAPONS_LENGTH; ++i)
        {
            // Clear and skip if prioritised not set.
            Slot slot = this.GetWeaponSlot(i);
            if (slot.m_Prioritised == NULL_DEFINITION)
            {
                slot.m_Cached = NULL_DEFINITION;
                continue;
            }

            // Retrieve the currently equipped weapon.
            int econentity = slot.GetWeapon();

            // If still invalid, continue.
            if (econentity == INVALID_ENT_REFERENCE)
            {
                slot.m_Cached = NULL_DEFINITION;
                continue;
            }

            // Cache the definition for this weapon.
            int itemdef = ((slot.m_iCachedItemDefinitionIndex != TF_ITEMDEF_DEFAULT) ? slot.m_iCachedItemDefinitionIndex : GetEntProp(econentity, Prop_Send, "m_iItemDefinitionIndex"));
            slot.m_Cached = Definition.FromItemDefinitionIndex(itemdef);
        }
    }

    // Re-configure this player's loadout.
    public void SortLoadout()
    {
        // Check if this is the first time the player's spawning.
        // If so, just skip this.
        if (g_PlayerData[this.entindex].m_bFirstTime)
        {
            g_PlayerData[this.entindex].m_bFirstTime = false;
            g_PlayerData[this.entindex].m_bDoNotSetSpawning = true;
            return;
        }

        // Loadout reconstruction.
        this.CorrectWeapons();
        this.ConstructLoadout();
        this.CacheCurrentLoadout();

        // Equip a designated slot if requested.
        if (g_PlayerData[this.entindex].m_iSlotToEquip != -1)
        {
            Slot slot = this.GetSlot(g_PlayerData[this.entindex].m_iSlotToEquip);
            if (IsValidEntity(slot.m_hReplacement))
            {
                SetEntPropEnt(this.entindex, Prop_Send, "m_hActiveWeapon", slot.m_hReplacement);
                SDKCall(SDKCall_CBaseCombatWeapon_Deploy, slot.m_hReplacement);
            }
            g_PlayerData[this.entindex].m_iSlotToEquip = -1;
        }
    }
}

methodmap PlayerData
{
    // Constructor.
    public PlayerData(int index)
    {
        return view_as<PlayerData>(index);
    }

    // The player's entindex.
    property int entindex
    {
        public get() { return view_as<int>(this); }
    }

    // Get the player's current class.
    property TFClassType m_eClass
    {
        public get() { return TF2_GetPlayerClass(this.entindex); }
    }

    // Get the current slot chosen in the loadout menu.
    property int m_iLoadoutSlot
    {
        public get() { return g_PlayerData[this.entindex].m_iLoadoutSlot; }
        public set(int value) { g_PlayerData[this.entindex].m_iLoadoutSlot = value; }
    }

    // Get a page in the player's inventory.
    public Inventory GetInventory(any class = -1)
    {
        return Inventory(this.entindex, class);
    }
}

static bool TF2Econ_FilterByStock(int itemdef, any data)
{
    return TF2Econ_IsItemInBaseSet(itemdef);
}

//////////////////////////////////////////////////////////////////////////////
// INITIALISATION                                                           //
//////////////////////////////////////////////////////////////////////////////

public void OnPluginStart()
{
    LoadTranslations("common.phrases");
    g_AllLoaded = false;
 
    // Load gamedata.
    GameData config = LoadGameConfigFile(PLUGIN_NAME);
    if (!config)
        SetFailState("Failed to load gamedata from \"%s\".", PLUGIN_NAME);

    // Set up detours.
    DHooks_CTFPlayer_GetLoadoutItem = DynamicDetour.FromConf(config, "CTFPlayer::GetLoadoutItem()");
    DHooks_CTFPlayer_GetLoadoutItem.Enable(Hook_Post, CTFPlayer_GetLoadoutItem);

    DHooks_CTFPlayer_ManageRegularWeapons = DynamicDetour.FromConf(config, "CTFPlayer::ManageRegularWeapons()");
    DHooks_CTFPlayer_ManageRegularWeapons.Enable(Hook_Pre, CTFPlayer_ManageRegularWeapons_Pre);
    DHooks_CTFPlayer_ManageRegularWeapons.Enable(Hook_Post, CTFPlayer_ManageRegularWeapons_Post);

    DHooks_CTFPlayer_ValidateWeapons = DynamicDetour.FromConf(config, "CTFPlayer::ValidateWeapons()");
    DHooks_CTFPlayer_ValidateWeapons.Enable(Hook_Pre, CTFPlayer_ValidateWeapons_Pre);
    DHooks_CTFPlayer_ValidateWeapons.Enable(Hook_Post, CTFPlayer_ValidateWeapons_Post);

    DHooks_CTFPlayer_GetMaxAmmo = DynamicDetour.FromConf(config, "CTFPlayer::GetMaxAmmo()");
    DHooks_CTFPlayer_GetMaxAmmo.Enable(Hook_Pre, CTFPlayer_GetMaxAmmo);

    DHooks_CTFPlayer_Spawn = DynamicDetour.FromConf(config, "CTFPlayer::Spawn()");
    DHooks_CTFPlayer_Spawn.Enable(Hook_Pre, CTFPlayer_Spawn);

    DHooks_CTFAmmoPack_PackTouch = DynamicDetour.FromConf(config, "CTFAmmoPack::PackTouch()");
    DHooks_CTFAmmoPack_PackTouch.Enable(Hook_Post, CTFAmmoPack_PackTouch);

    DHooks_CAmmoPack_MyTouch = DynamicDetour.FromConf(config, "CAmmoPack::MyTouch()");
    DHooks_CAmmoPack_MyTouch.Enable(Hook_Post, CAmmoPack_MyTouch);

    DHooks_CObjectDispenser_DispenseAmmo = DynamicDetour.FromConf(config, "CObjectDispenser::DispenseAmmo()");
    DHooks_CObjectDispenser_DispenseAmmo.Enable(Hook_Post, CObjectDispenser_DispenseAmmo);

    // Set up SDKCalls.
    StartPrepSDKCall(SDKCall_Player);
    PrepSDKCall_SetFromConf(config, SDKConf_Virtual, "CTFPlayer::EquipWearable()");
    PrepSDKCall_AddParameter(SDKType_CBaseEntity, SDKPass_Pointer); // CBaseEntity*
    SDKCall_CTFPlayer_EquipWearable = EndPrepSDKCall();

    StartPrepSDKCall(SDKCall_Player);
    PrepSDKCall_SetFromConf(config, SDKConf_Virtual, "CTFPlayer::GiveNamedItem()");
    PrepSDKCall_AddParameter(SDKType_String, SDKPass_Pointer);      // const char *pszName
    PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Plain);  // int iSubType
    PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Plain);  // const CEconItemView *pScriptItem
    PrepSDKCall_AddParameter(SDKType_Bool, SDKPass_Plain);          // bool bForce
    PrepSDKCall_SetReturnInfo(SDKType_CBaseEntity, SDKPass_Pointer, (VDECODE_FLAG_ALLOWNULL | VDECODE_FLAG_ALLOWNOTINGAME | VDECODE_FLAG_ALLOWWORLD));
    SDKCall_CTFPlayer_GiveNamedItem = EndPrepSDKCall();

    StartPrepSDKCall(SDKCall_Entity);
    PrepSDKCall_SetFromConf(config, SDKConf_Virtual, "CBaseCombatWeapon::Deploy()");
    PrepSDKCall_SetReturnInfo(SDKType_Bool, SDKPass_Plain);         // bool
    SDKCall_CBaseCombatWeapon_Deploy = EndPrepSDKCall();

    // Set offsets.
    CUtlVector_m_Size = config.GetOffset("CUtlVector::m_Size");
    CTFWearable_m_bAlwaysAllow = config.GetOffset("CTFWearable::m_bAlwaysAllow");
    CEconEntity_m_iItemID = FindSendPropInfo("CEconEntity", "m_iItemIDHigh") - 8;
    CTFWeaponBase_m_eStatTrakModuleType = FindSendPropInfo("CTFWeaponBase", "m_bLowered") - 4;
    CTFWeaponBase_m_eStrangeType = CTFWeaponBase_m_eStatTrakModuleType - 4;

    // Delete GameData handle.
    delete config;

    // Set up global forwrads.
    g_LoadedDefinitionsForward = new GlobalForward("WeaponManager_OnDefinitionsLoaded", ET_Ignore, Param_Cell);
    g_ConstructingLoadout = new GlobalForward("WeaponManager_OnLoadoutConstruction", ET_Ignore, Param_Cell, Param_Cell);
    g_ConstructingLoadoutPost = new GlobalForward("WeaponManager_OnLoadoutConstructionPost", ET_Ignore, Param_Cell, Param_Cell);

    // Fill class data.
    g_Classes = new StringMap();
    g_Classes.SetValue("scout", TFClass_Scout);
    g_Classes.SetValue("soldier", TFClass_Soldier);
    g_Classes.SetValue("pyro", TFClass_Pyro);
    g_Classes.SetValue("demo", TFClass_DemoMan);
    g_Classes.SetValue("demoman", TFClass_DemoMan);
    g_Classes.SetValue("heavy", TFClass_Heavy);
    g_Classes.SetValue("hwg", TFClass_Heavy);
    g_Classes.SetValue("heavyweaponsguy", TFClass_Heavy);
    g_Classes.SetValue("engineer", TFClass_Engineer);
    g_Classes.SetValue("engi", TFClass_Engineer);
    g_Classes.SetValue("engie", TFClass_Engineer);
    g_Classes.SetValue("medic", TFClass_Medic);
    g_Classes.SetValue("sniper", TFClass_Sniper);
    g_Classes.SetValue("spy", TFClass_Spy);

    // Fill weapon name data.
    g_StockWeaponNames = new StringMap();
    g_StockWeaponNames.SetString("TF_WEAPON_BAT", "The Bat");
    g_StockWeaponNames.SetString("TF_WEAPON_BOTTLE", "The Bottle");
    g_StockWeaponNames.SetString("TF_WEAPON_FIREAXE", "The Fire Axe");
    g_StockWeaponNames.SetString("TF_WEAPON_CLUB", "The Kukri");
    g_StockWeaponNames.SetString("TF_WEAPON_KNIFE", "The Knife");
    g_StockWeaponNames.SetString("TF_WEAPON_FISTS", "The Fists");
    g_StockWeaponNames.SetString("TF_WEAPON_SHOVEL", "The Shovel");
    g_StockWeaponNames.SetString("TF_WEAPON_WRENCH", "The Wrench");
    g_StockWeaponNames.SetString("TF_WEAPON_BONESAW", "The Bonesaw");
    g_StockWeaponNames.SetString("TF_WEAPON_SHOTGUN_PRIMARY", "The Shotgun (Engineer)");
    g_StockWeaponNames.SetString("TF_WEAPON_SHOTGUN_SOLDIER", "The Shotgun (Soldier)");
    g_StockWeaponNames.SetString("TF_WEAPON_SHOTGUN_HWG", "The Shotgun (Heavy)");
    g_StockWeaponNames.SetString("TF_WEAPON_SHOTGUN_PYRO", "The Shotgun (Pyro)");
    g_StockWeaponNames.SetString("TF_WEAPON_SCATTERGUN", "The Scattergun");
    g_StockWeaponNames.SetString("TF_WEAPON_SNIPERRIFLE", "The Sniper Rifle");
    g_StockWeaponNames.SetString("TF_WEAPON_MINIGUN", "The Minigun");
    g_StockWeaponNames.SetString("TF_WEAPON_SMG", "The SMG");
    g_StockWeaponNames.SetString("TF_WEAPON_SYRINGEGUN_MEDIC", "The Syringe Gun");
    g_StockWeaponNames.SetString("TF_WEAPON_ROCKETLAUNCHER", "The Rocket Launcher");
    g_StockWeaponNames.SetString("TF_WEAPON_GRENADELAUNCHER", "The Grenade Launcher");
    g_StockWeaponNames.SetString("TF_WEAPON_PIPEBOMBLAUNCHER", "The Stickybomb Launcher");
    g_StockWeaponNames.SetString("TF_WEAPON_FLAMETHROWER", "The Flame Thrower");
    g_StockWeaponNames.SetString("TF_WEAPON_PISTOL", "The Pistol");
    g_StockWeaponNames.SetString("TF_WEAPON_REVOLVER", "The Revolver");
    g_StockWeaponNames.SetString("TF_WEAPON_PDA_ENGINEER_BUILD", "The Construction PDA");
    g_StockWeaponNames.SetString("TF_WEAPON_PDA_ENGINEER_DESTROY", "The Destruction PDA");
    g_StockWeaponNames.SetString("TF_WEAPON_PDA_SPY", "The Disguise Kit");
    g_StockWeaponNames.SetString("TF_WEAPON_BUILDER", "The PDA Engineer");
    g_StockWeaponNames.SetString("TF_WEAPON_MEDIGUN", "The Medi Gun");
    g_StockWeaponNames.SetString("TF_WEAPON_INVIS", "The Invis Watch");
    g_StockWeaponNames.SetString("TF_WEAPON_BUILDER_SPY", "The Sapper");
    g_StockWeaponNames.SetString("TTG Max Pistol", "The Lugermorph");
    g_StockWeaponNames.SetString("TTG Max Pistol - Poker Night", "The Lugermorph");
    g_StockWeaponNames.SetString("TTG Sam Revolver", "The Big Kill");
    g_StockWeaponNames.SetString("Panic Attack Shotgun", "The Panic Attack");

    // Set max ammo table.
    g_MaxAmmo[TFClass_Scout] = { 0, 32, 36, 100, 1, 1, 0 };
    g_MaxAmmo[TFClass_Soldier] = { 0, 20, 32, 100, 1, 1, 0 };
    g_MaxAmmo[TFClass_Pyro] = { 0, 200, 32, 100, 1, 0, 0 };
    g_MaxAmmo[TFClass_DemoMan] = { 0, 16, 24, 100, 1, 1, 0 };
    g_MaxAmmo[TFClass_Heavy] = { 0, 200, 32, 100, 1, 1, 0 };
    g_MaxAmmo[TFClass_Engineer] = { 0, 32, 200, 200, 0, 0, 0 };
    g_MaxAmmo[TFClass_Medic] = { 0, 150, 150, 100, 0, 0, 0 };
    g_MaxAmmo[TFClass_Sniper] = { 0, 25, 75, 100, 1, 0, 0};
    g_MaxAmmo[TFClass_Spy] = { 0, 20, 24, 100, 0, 1, 0 };

    // Clear g_EntityData.
    for (int i = 0; i < MAXENTITIES; ++i)
    {
        if (IsValidEntity(i))
        {
            char classname[64];
            GetEntityClassname(i, classname, sizeof(classname));
            OnEntityCreated(i, classname);
        }
    }

    // Clear inventories and load hooks.
    for (int i = 1; i <= MaxClients; ++i)
    {
        if (IsClientInGame(i))
            ClearLoadout(i);
    }

    // Set up events.
    HookEvent("post_inventory_application", post_inventory_application);
}

public void OnPluginEnd()
{
    // Walk through each player's slots.
    for (int client = 1; client <= MaxClients; ++client)
    {
        // Verify that the class is in-game.
        if (!IsClientInGame(client))
            continue;

        // Unload this weapon on CWX's side.
        CWXUnload(client);

        // Get player data and iterate through slots.
        PlayerData data = PlayerData(client);
        Inventory inventory = data.GetInventory();
        for (int slot = 0; slot < WEAPONS_LENGTH; ++slot)
        {
            Slot slotinfo = inventory.GetWeaponSlot(slot);
            if (IsValidEntity(slotinfo.m_hReplacement))
            {
                // Make sure wearables can be removed on resupply.
                char buffer[ENTITY_NAME_LENGTH];
                GetEntityClassname(slotinfo.m_hReplacement, buffer, sizeof(buffer));
                if (StrContains(buffer, "tf_wearable") == 0)
                    SetEntData(slotinfo.m_hReplacement, CTFWearable_m_bAlwaysAllow, false, 1);

                // Really there's no sustainable way to maintain custom slot weapons so just delete them.
                if (IsValidEntity(slotinfo.m_hFakeSlotReplacement))
                {
                    TF2_RemoveWeapon(client, slotinfo.m_hReplacement);
                    TF2_RemoveWeapon(client, slotinfo.m_hFakeSlotReplacement);
                }
            }
        }
    }

    // Export the config.
    if (FileExists(AUTOSAVE_PATH))
        ExportKeyValues(AUTOSAVE_PATH);
}

static void LoadDefaults()
{
    strcopy(g_szCurrentPath, sizeof(g_szCurrentPath), AUTOSAVE_PATH);
}

//////////////////////////////////////////////////////////////////////////////
// LIBRARIES                                                                //
//////////////////////////////////////////////////////////////////////////////

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
    // Register natives within this plugin.
    CreateNative("WeaponManager_IsPluginReady", Native_WeaponManager_IsPluginReady);
    CreateNative("WeaponManager_GetDefinitions", Native_WeaponManager_GetDefinitions);
    CreateNative("WeaponManager_SetDefinitions", Native_WeaponManager_SetDefinitions);
    CreateNative("WeaponManager_Write", Native_WeaponManager_Write);
    CreateNative("WeaponManager_Load", Native_WeaponManager_Load);
    CreateNative("WeaponManager_Refresh", Native_WeaponManager_Refresh);
    CreateNative("WeaponManager_GetLoadedConfig", Native_WeaponManager_GetLoadedConfig);
    CreateNative("WeaponManager_DispatchGlobalKeyValue", Native_WeaponManager_DispatchGlobalKeyValue);
    CreateNative("WeaponManager_GetGlobalKeyValue", Native_WeaponManager_GetGlobalKeyValue);
    CreateNative("WeaponManager_DispatchConfigKeyValue", Native_WeaponManager_DispatchConfigKeyValue);
    CreateNative("WeaponManager_GetConfigKeyValue", Native_WeaponManager_GetConfigKeyValue);
    CreateNative("WeaponManager_FindDefinition", Native_WeaponManager_FindDefinition);
    CreateNative("WeaponManager_FindDefinitionByItemDef", Native_WeaponManager_FindDefinitionByItemDef);
    CreateNative("WeaponManager_EquipDefinition", Native_WeaponManager_EquipDefinition);
    CreateNative("WeaponManager_ForcePersistDefinition", Native_WeaponManager_ForcePersistDefinition);
    CreateNative("WeaponManager_RemovePersistedDefinition", Native_WeaponManager_RemovePersistedDefinition);
    CreateNative("WeaponManager_DefinitionAllowed", Native_WeaponManager_DefinitionAllowed);
    CreateNative("WeaponManager_DefinitionAllowedByItemDef", Native_WeaponManager_DefinitionAllowedByItemDef);
    CreateNative("WeaponManager_GetWeapon", Native_WeaponManager_GetWeapon);
    CreateNative("WeaponManager_GetReplacementWeapon", Native_WeaponManager_GetReplacementWeapon);
    CreateNative("WeaponManager_GetFakeSlotReplacementWeapon", Native_WeaponManager_GetFakeSlotReplacementWeapon);
    CreateNative("WeaponManager_GetSlotOfWeapon", Native_WeaponManager_GetSlotOfWeapon);
    CreateNative("WeaponManager_MedievalMode_DefinitionAllowed", Native_WeaponManager_MedievalMode_DefinitionAllowed);
    CreateNative("WeaponManager_MedievalMode_DefinitionAllowedByItemDef", Native_WeaponManager_MedievalMode_DefinitionAllowedByItemDef);

    // Register this plugin as a library.
    RegPluginLibrary("NotnHeavy - Weapon Manager");

    // Mark these natives as optional in case CWX isn't loaded.
    MarkNativeAsOptional("CWX_GetPlayerLoadoutItem");
    MarkNativeAsOptional("CWX_RemovePlayerLoadoutItem");
    MarkNativeAsOptional("CWX_CanPlayerAccessItem");
    return APLRes_Success;
}

// doesn't use OnAllPluginsLoaded() due to gamerules checks
public void OnMapStart()
{
    // Continue plugin loading here.
    PrintToServer("--------------------------------------------------------");
    g_LoadedCWX = LibraryExists("cwx");

    // Parse attribute_manager.cfg.
    if (!FileExists(GLOBALS_PATH, true))
    {
        LoadDefaults();
        PrintToServer("\"%s\" doesn't exist, not parsing globals...\n", GLOBALS_PATH);
    }
    else
    {
        PrintToServer("Parsing weapon_manager.cfg:");

        KeyValues kv = new KeyValues("Settings");
        kv.ImportFromFile(GLOBALS_PATH);
        
        kv.GetString("defaultconfig", g_szCurrentPath, sizeof(g_szCurrentPath), GLOBALS_PATH);
        g_bPrintAllDefs = !!(kv.GetNum("printalldefs"));
        g_eLoadoutMenu = view_as<LoadoutOptions_t>(kv.GetNum("loadoutmenu"));
        g_eCommands = view_as<LoadoutOptions_t>(kv.GetNum("equipcommands"));

        PrintToServer("- #printalldefs: %s", (g_bPrintAllDefs ? "true" : "false"));
        if (strlen(g_szCurrentPath) == 0)
        {
            strcopy(g_szCurrentPath, sizeof(g_szCurrentPath), AUTOSAVE_PATH);
            PrintToServer("- #defaultconfig: blank, defaulting to \"%s\"", AUTOSAVE_PATH);
        }
        else 
        {
            PrintToServer("- #defaultconfig: \"%s\"", g_szCurrentPath);
            if (strcmp(g_szCurrentPath, GLOBALS_PATH) != 0)
                Format(g_szCurrentPath, sizeof(g_szCurrentPath), "addons/sourcemod/configs/weapon_manager/%s.cfg", g_szCurrentPath);
        }
        PrintToServer("g_szCurrentPath set to \"%s\".", g_szCurrentPath);

        PrintToServer("");
        delete kv;
    }

    // Get a list of all stock weapons.
    g_StockItems = TF2Econ_GetItemList(TF2Econ_FilterByStock);

    // Create the ArrayList and fill it with definitions, if an autosave is present.
    g_Definitions = new StringMap();
    if (!FileExists(g_szCurrentPath, true))
        PrintToServer("\"%s\" doesn't exist, will only parse internal definitions...", g_szCurrentPath);
    ParseDefinitions(g_szCurrentPath);

    // Register a list of commands server admins can use.
    RegAdminCmd("weapon_write", weapon_write, ADMFLAG_GENERIC, "Creates a file (if it doesn't exist beforehand) and writes all definitions to it. If no name is provided, it will write to autosave.cfg.\nSyntax: weapon_write configname");
    RegAdminCmd("weapon_loadconfig", weapon_loadconfig, ADMFLAG_GENERIC, "Load definitions from an existing config.\nSyntax: weapon_loadconfig configname");
    RegAdminCmd("weapon_load", weapon_loadconfig, ADMFLAG_GENERIC, "Load definitions from an existing config.\nSyntax: weapon_load configname");
    RegAdminCmd("weapon_listdefinitions", weapon_listdefinitions, ADMFLAG_GENERIC, "List all the names of the current definitions.\nSyntax: weapon_listdefinitions [class] [slot (0 - Primary | 1 - Secondary | 2 - Secondary | 3 - Disguise Kit/Construction PDA | 4 - Watch/Destruction PDA)]");
    RegAdminCmd("weapon_listdefs", weapon_listdefinitions, ADMFLAG_GENERIC, "List all the names of the current definitions.\nSyntax: weapon_listdefs [class] [slot (0 - Primary | 1 - Secondary | 2 - Secondary | 3 - Disguise Kit/Construction PDA | 4 - Watch/Destruction PDA)]");
    RegAdminCmd("weapon_list", weapon_listdefinitions, ADMFLAG_GENERIC, "List all the names of the current definitions.\nSyntax: weapon_list [class] [slot (0 - Primary | 1 - Secondary | 2 - Secondary | 3 - Disguise Kit/Construction PDA | 4 - Watch/Destruction PDA)]");
    RegAdminCmd("weapon_add", weapon_add, ADMFLAG_GENERIC, "Add a new definition (native weapon, cwx weapon (must configure with weapon_modify!) or custom tag). If specified, it can inherit from another definition.\nSyntax: weapon_add (name | item definition index) [inherits]");
    RegAdminCmd("weapon_remove", weapon_remove, ADMFLAG_GENERIC, "Remove a definition (native weapon, cwx weapon or custom tag)\nSyntax: weapon_remove (name | item definition index)");
    RegAdminCmd("weapon_delete", weapon_remove, ADMFLAG_GENERIC, "Remove a definition (native weapon, cwx weapon or custom tag)\nSyntax: weapon_delete (name | item definition index)");
    RegAdminCmd("weapon_del", weapon_remove, ADMFLAG_GENERIC, "Remove a definition (native weapon, cwx weapon or custom tag)\nSyntax: weapon_del (name | item definition index)");
    RegAdminCmd("weapon_modify", weapon_modify, ADMFLAG_GENERIC, "Modify a definition's property.\nSyntax: weapon_modify (name | item definition index) property value");
    RegAdminCmd("weapon_refresh", weapon_refresh, ADMFLAG_GENERIC, "Reparse all definitions.\nSyntax: weapon_refresh");
    RegAdminCmd("weapon_toggleslot", weapon_toggleslot, ADMFLAG_GENERIC, "Toggle's a definition's slot.\nSyntax: weapon_toggleslot (name | item definition index) class slot (0 - Primary | 1 - Secondary | 2 - Secondary | 3 - Disguise Kit/Construction PDA | 4 - Watch/Destruction PDA) value");
    RegAdminCmd("weapon_toggle", weapon_toggleslot, ADMFLAG_GENERIC, "Toggle's a definition's slot.\nSyntax: weapon_toggle (name | item definition index) class slot (0 - Primary | 1 - Secondary | 2 - Secondary | 3 - Disguise Kit/Construction PDA | 4 - Watch/Destruction PDA) value");
    RegAdminCmd("weapon_disable", weapon_disable, ADMFLAG_GENERIC, "Disable a definition for every slot for a class.\nSyntax: weapon_disable (name | item definition index) class");
    RegAdminCmd("weapon_block", weapon_disable, ADMFLAG_GENERIC, "Disable a definition for every slot for a class.\nSyntax: weapon_block (name | item definition index) class");
    RegAdminCmd("weapon_listdefinition", weapon_listdefinition, ADMFLAG_GENERIC, "List the properties of a definition.\nSyntax: weapon_listdefinition (name | item definition index)");
    RegAdminCmd("weapon_listdef", weapon_listdefinition, ADMFLAG_GENERIC, "List the properties of a definition.\nSyntax: weapon_listdef (name | item definition index)");
    RegAdminCmd("weapon_giveto", weapon_giveto, ADMFLAG_GENERIC, "Give a weapon immediately to a player. You can choose whether it should persist.\nSyntax: weapon_giveto player slot (name | item definition index) [persist]");
    RegAdminCmd("weapon_givetonext", weapon_givetonext, ADMFLAG_GENERIC, "Assign a weapon to a player, which will be equipped on resupply.\nSyntax: weapon_givetonext player class slot (name | item definition index)");
    RegAdminCmd("weapon_unequipfrom", weapon_unequipfrom, ADMFLAG_GENERIC, "Unequip a weapon from a player, which will take place on resupply.\nSyntax: weapon_unequipfrom player class slot");

    // Register console commands for users to use to equip weapons.
    RegConsoleCmd("loadout", cmd_loadout);
    RegConsoleCmd("gimme", cmd_gimme);
    RegConsoleCmd("gimmenext", cmd_gimmenext);
    RegConsoleCmd("unequip", cmd_unequip);

    // Show to the server maintainer what plugins are currently loaded.
    PrintToServer("\nCustom Weapons X: %s", (g_LoadedCWX ? "loaded" : "not loaded"));

    // Cache sounds.
    PrecacheSound("AmmoPack.Touch", true);

    // Create ConVars.
    char buffer[2];
    Format(buffer, sizeof(buffer), "%i", (GameRules_GetProp("m_bPlayingMedieval", 1) ? true : false));
    weaponmanager_medievalmode = CreateConVar("weaponmanager_medievalmode", buffer, "Configures whether Medieval Mode is on (by configuring CTFGameRules::m_bPlayingMedieval).", (FCVAR_REPLICATED | FCVAR_SPONLY), true, 0.00, true, 1.00);
    weaponmanager_medievalmode.AddChangeHook(MedievalModeToggled);
    weaponmanager_medievalmode.SetString(buffer, true);

    // Plugin ready.
    g_AllLoaded = true;
    Call_StartForward(g_LoadedDefinitionsForward);
    Call_PushCell(true);
    Call_Finish();
    PrintToServer("\n\"%s\" has loaded.\n--------------------------------------------------------", PLUGIN_NAME);
}

public void OnLibraryAdded(const char[] name)
{
    if (!g_AllLoaded)
        return;

    if (strcmp("cwx", name) == 0)
    {
        g_LoadedCWX = true;
        if (FileExists(g_szCurrentPath, true))
            ParseDefinitions(g_szCurrentPath);
    }
}

public void OnLibraryRemoved(const char[] name)
{
    if (strcmp("cwx", name) == 0)
        g_LoadedCWX = false;
}

//////////////////////////////////////////////////////////////////////////////
// PLAYER CODE                                                              //
//////////////////////////////////////////////////////////////////////////////

public void OnClientPutInServer(int client)
{
    CWXUnload(client);
    ClearLoadout(client);
    g_PlayerData[client].m_bFirstTime = true;
}

public Action CTFPlayer_WeaponCanSwitchTo(int client, int weapon)
{
    // Get player's inventory.
    PlayerData data = PlayerData(client);
    Inventory inventory = data.GetInventory();

    // Walk through each slot.
    for (int i = 0; i < WEAPONS_LENGTH; ++i)
    {
        Slot slot = inventory.GetWeaponSlot(i);

        // Check if we are equipping one of the fake slot replacements.
        if (slot.m_hFakeSlotReplacement == EntIndexToEntRef(weapon))
        {
            // Sanity checks.
            int active = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
            if (!IsValidEntity(active))
                return Plugin_Continue;
            if (!IsValidEntity(slot.m_hReplacement))
                return Plugin_Continue;

            // Skip this switch if the equipped weapon is the desired weapon and the weapon to be
            // switched to is the fake slot replacement.
            if (slot.m_hReplacement == EntIndexToEntRef(active))
                return Plugin_Handled;

            // Skip further checks if the equipped weapon does not have a valid ammo type.
            if (!(TF_AMMO_PRIMARY <= g_EntityData[EntRefToEntIndex(slot.m_hReplacement)].m_iPrimaryAmmoType < TF_AMMO_COUNT))
                return Plugin_Continue;
            
            // Skip this switch if the desired weapon has ran out of ammo.
            int clip = GetEntProp(slot.m_hReplacement, Prop_Send, "m_iClip1");
            if ((clip == 0 || clip == 255) && GetEntProp(client, Prop_Send, "m_iAmmo", .element = GetEntProp(slot.m_hReplacement, Prop_Send, "m_iPrimaryAmmoType")) == 0)
                return Plugin_Handled;

            // Continue.
            return Plugin_Continue;
        }
    }

    // Continue.
    return Plugin_Continue;
}

public void CTFPlayer_WeaponSwitchPost(int client, int weapon)
{
    // Get player's inventory.
    PlayerData data = PlayerData(client);
    Inventory inventory = data.GetInventory();

    // Weird sanity check.
    if (!IsValidEntity(weapon))
        return;

    // Skip if the active weapon is not this weapon.
    if (GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon") != weapon)
        return;

    // Walk through each slot.
    for (int i = 0; i < WEAPONS_LENGTH; ++i)
    {
        Slot slot = inventory.GetWeaponSlot(i);

        // Skip if replacement weapon is not valid.
        if (!IsValidEntity(slot.m_hReplacement))
            continue;

        // Check if this is a fake slot replacement weapon.
        if (slot.m_hFakeSlotReplacement == EntIndexToEntRef(weapon))
        {
            // This is a fake slot replacement weapon - equip the actual weapon instead and inhibit this switch.
            SetEntPropEnt(client, Prop_Send, "m_hActiveWeapon", slot.m_hReplacement);
            SDKCall(SDKCall_CBaseCombatWeapon_Deploy, slot.m_hReplacement);
            return;
        }
    }

    // Continue as per usual.
    return;
}

static void ClearLoadout(int client)
{
    g_PlayerData[client].m_eLastClass = TF2_GetPlayerClass(client);
    for (TFClassType class = TFClass_Unknown; class <= TFClass_Engineer; ++class)
        PlayerData(client).GetInventory(class).Clear();
    SDKHook(client, SDKHook_WeaponCanSwitchTo, CTFPlayer_WeaponCanSwitchTo);
    SDKHook(client, SDKHook_WeaponSwitchPost, CTFPlayer_WeaponSwitchPost);
}

static void CWXUnload(int client)
{
    // Sanity check?
    if (!(1 <= client <= MaxClients) || !IsValidEntity(client) || !HasEntProp(client, Prop_Send, "m_iClass"))
        return;

    // Get player data.
    PlayerData data = PlayerData(client);

    // Walk through each class inventory.
    for (TFClassType class = TFClass_Scout; class <= TFClass_Engineer; ++class)
    {
        Inventory inventory = data.GetInventory(class);

        // Walk through each slot and unload it if it is CWX.
        for (int slot = 0; slot < WEAPONS_LENGTH; ++slot)
        {
            Slot slotinfo = inventory.GetWeaponSlot(slot);
            definition_t def;
            if (slotinfo.m_Prioritised != NULL_DEFINITION)
            {
                slotinfo.m_Prioritised.Get(def);
                if (strlen(def.m_szCWXUID) > 0 && g_LoadedCWX)
                    CWX_RemovePlayerLoadoutItem(client, class, LoadoutToTF2(slot, class), LOADOUT_FLAG_UPDATE_BACKEND);
            }
        }
    }
}

static int GetMaxAmmo(int client, int type, TFClassType class)
{
    // Find which weapon is using the desired ammo type.
    for (int i = 0; i < MAX_WEAPONS; ++i)
    {
        // Verify this weapon slot.
        int weapon = GetEntPropEnt(client, Prop_Send, "m_hMyWeapons", i);
        if (!IsValidEntity(weapon))
            continue;
        
        // Verify that the ammo types are the same.
        int foundtype = GetEntProp(weapon, Prop_Send, "m_iPrimaryAmmoType");
        if (foundtype == type)
        {
            // Get the initial value.
            int value = ((g_EntityData[weapon].m_iPrimaryAmmoType == TF_AMMO_GRENADES3) ? 1 : g_MaxAmmo[class][g_EntityData[weapon].m_iPrimaryAmmoType]);

            // Check if the player has the Haste Powerup Rune.
            if (TF2_IsPlayerInCondition(client, TFCond_RuneHaste))
                value *= 2.0;

            // Return the value.
            return value;
        }
    }

    // Could not find anything. 
    return 0;
}

static void ClientNoLongerSpawning(int client)
{
    g_PlayerData[client].m_bSpawning = false;
}

// This function is complicated.
// We will call EquipPlayerWeapon() like we do with m_ToEquip[i], however beforehand
// we must fill any vacant slots with fake weapons.
//
// This is to fix persistency issues when players equip wearables and custom slot
// weapons, as there may be a gap between the real weapons that a custom slot weapon
// may fill, which may prevent you from equipping an actual weapon in another slot.
static void ClearEquipLastBacklog(int client)
{
    // First, calculate the offset of the final valid weapon + 1.
    int length = MAX_WEAPONS - 1;
    for (int i = length; i >= 0; --i)
    {
        int weapon = GetEntPropEnt(client, Prop_Send, "m_hMyWeapons", i);
        if (weapon != INVALID_ENT_REFERENCE)
        {
            length = i + 1;
            break;
        }
    }

    // Now iterate until the cached length and equip fake weapons every time we
    // encounter a vacant slot.
    for (int i = 0; i < length; ++i)
    {
        int weapon = GetEntPropEnt(client, Prop_Send, "m_hMyWeapons", i);
        if (weapon == INVALID_ENT_REFERENCE)
            EquipPlayerWeapon(client, CreateFakeWeapon());
    }

    // Now equip weapons like normally.
    for (int i = 0; i < g_PlayerData[client].m_iLastEquipIndex; ++i)
    {
        int weapon = g_PlayerData[client].m_ToEquipLast[i];
        if (!IsValidEntity(weapon) || GetEntityFlags(weapon) & FL_KILLME)
            continue;
        EquipPlayerWeapon(client, g_PlayerData[client].m_ToEquipLast[i]);
    }
    g_PlayerData[client].m_iLastEquipIndex = 0;
}

//////////////////////////////////////////////////////////////////////////////
// WEAPON CODE                                                              //
//////////////////////////////////////////////////////////////////////////////

public void OnEntityCreated(int entity, const char[] classname)
{
    // Clear entity data.
    if (!(0 <= entity < MAXENTITIES))
        return;
    g_EntityData[entity].reference = EntIndexToEntRef(entity);
    g_EntityData[entity].slot = -1;
    g_EntityData[entity].m_hFakeSlotReference = INVALID_ENT_REFERENCE;
    g_EntityData[entity].m_iPrimaryAmmoType = -1;
    
    // If this is a weapon, hook when it is going to spawn.
    if (HasEntProp(entity, Prop_Send, "m_iItemDefinitionIndex"))
        SDKHook(entity, SDKHook_SpawnPost, CEconEntity_Spawn_Post);
}

static int GetItemLoadoutSlotOfWeapon(int weapon, TFClassType class)
{
    // Validate weapon.
    if (!IsValidEntity(weapon))
        return TF_ITEMDEF_DEFAULT;
    if (!HasEntProp(weapon, Prop_Send, "m_iItemDefinitionIndex"))
        return TF_ITEMDEF_DEFAULT;

    // Does it have a cached slot?
    if (EntIndexToEntRef(weapon) == g_EntityData[weapon].reference && g_EntityData[weapon].slot != -1)
        return g_EntityData[weapon].slot;
    
    // Look up this weapon's itemdef and just call TF2Econ_GetItemLoadoutSlot().
    int itemdef = GetEntProp(weapon, Prop_Send, "m_iItemDefinitionIndex");
    return TF2Econ_GetItemLoadoutSlot(itemdef, class);
}

static void ItemsMatchClearup(Slot slot, int newitemdef)
{
    // Clear slot information.
    slot.m_iCachedItemDefinitionIndex = TF_ITEMDEF_DEFAULT;
    if (IsValidEntity(slot.m_hFakeSlotReplacement))
        TF2_RemoveWeapon(slot.entindex, slot.m_hFakeSlotReplacement);
    if (IsValidEntity(slot.m_hReplacement))
    {
        char buffer[ENTITY_NAME_LENGTH];
        GetEntityClassname(slot.m_hReplacement, buffer, sizeof(buffer));
        if (StrContains(buffer, "tf_wearable") == 0)
            TF2_RemoveWearable(slot.entindex, EntRefToEntIndex(slot.m_hReplacement));
        else
            TF2_RemoveWeapon(slot.entindex, slot.m_hReplacement);
    }
    if (slot.m_Prioritised == slot.m_Selected && slot.m_bTemporary)
    {
        slot.m_Selected = NULL_DEFINITION;
        slot.m_bTemporary = false;
    }

    // Choose another weapon to equip.
    if (0 <= newitemdef < sizeof(g_DefinitionsByIndex) && g_DefinitionsByIndex[newitemdef].m_bToggled)
    {
        definition_t def;
        view_as<Definition>(g_DefinitionsByIndex[newitemdef].m_Object).Get(def);
        if (!def.GetSlot(slot.m_eClass, slot.m_iSlotIndex))
            g_PlayerData[slot.entindex].m_iSlotToEquip = slot.m_iSlotIndex;
    }
}

static void TF2_RemoveWeapon(int client, int weapon)
{
    // TF2_RemoveWeaponSlot() modified
    int extraWearable = (HasEntProp(weapon, Prop_Send, "m_hExtraWearable") ? GetEntPropEnt(weapon, Prop_Send, "m_hExtraWearable") : INVALID_ENT_REFERENCE);
    if (extraWearable != INVALID_ENT_REFERENCE)
        TF2_RemoveWearable(client, extraWearable);

    extraWearable = (HasEntProp(weapon, Prop_Send, "m_hExtraWearableViewModel") ? GetEntPropEnt(weapon, Prop_Send, "m_hExtraWearableViewModel") : INVALID_ENT_REFERENCE);
    if (extraWearable != INVALID_ENT_REFERENCE)
        TF2_RemoveWearable(client, extraWearable);

    RemovePlayerItem(client, weapon);
    AcceptEntityInput(weapon, "Kill");
}

static void FixAmmo(Slot slot)
{
    // Skip if the replacement entity is invalid.
    if (!IsValidEntity(slot.m_hReplacement))
        return;

    // Fix edge-case bug where the Gas Passer is useable when equipped.
    if (HasEntProp(slot.m_hReplacement, Prop_Send, "m_iPrimaryAmmoType"))
    {
        int type = GetEntProp(slot.m_hReplacement, Prop_Send, "m_iPrimaryAmmoType");
        if (type == TF_AMMO_GRENADES1 && TF2Attrib_HookValueInt(0, "grenades1_resupply_denied", slot.m_hReplacement))
            SetEntProp(slot.entindex, Prop_Send, "m_iAmmo", 0, .element = type);
    }
    if (TF2Attrib_HookValueInt(0, "item_meter_resupply_denied", slot.m_hReplacement))
        SetEntPropFloat(slot.entindex, Prop_Send, "m_flItemChargeMeter", 0.00, .element = GetItemLoadoutSlotOfWeapon(EntRefToEntIndex(slot.m_hReplacement), slot.m_eClass));
}

static void TranslateWeaponEntForClass(char[] classname, int maxlength, TFClassType class)
{
    // Call the internal translation code.
    TF2Econ_TranslateWeaponEntForClass(classname, maxlength, class);
    
    // Do a few more tweaks as a result of custom slot weapon code.
    if (strcmp(classname, "tf_weapon_shotgun") == 0)
        strcopy(classname, maxlength, "tf_weapon_shotgun_primary");
    else if (strcmp(classname, "tf_weapon_revolver_secondary") == 0)
        strcopy(classname, maxlength, "tf_weapon_revolver");
}

static bool AllowedOnMedievalByDefault(int itemdef, TFClassType class)
{
    // Check the loadout slot of this item.
    int slot = TF2Econ_GetItemLoadoutSlot(itemdef, class);
    switch (slot)
    {
        case LOADOUT_POSITION_MELEE:
            return true;
        case LOADOUT_POSITION_HEAD:
            return true;
        case LOADOUT_POSITION_MISC:
            return true;
        case LOADOUT_POSITION_MISC2:
            return true;
        case LOADOUT_POSITION_TAUNT:
            return true;
        case LOADOUT_POSITION_TAUNT2:
            return true;
        case LOADOUT_POSITION_TAUNT3:
            return true;
        case LOADOUT_POSITION_TAUNT4:
            return true;
        case LOADOUT_POSITION_TAUNT5:
            return true;
        case LOADOUT_POSITION_TAUNT6:
            return true;
        case LOADOUT_POSITION_TAUNT7:
            return true;
        case LOADOUT_POSITION_TAUNT8:
            return true;
        case LOADOUT_POSITION_PDA, LOADOUT_POSITION_PDA2:
        {
            if (class == TFClass_Spy)
                return true;
        }
    }

    // Check if the item def has the "allowed in medieval mode" attribute by default.
    bool bMedievalModeAllowed = false;
    int attributes[16];
    float attributes_values[16];
    int count = TF2Attrib_GetStaticAttribs(itemdef, attributes, attributes_values);
    for (int i = 0; i < count; ++i)
    {
        if (attributes[i] == 2029 && attributes_values[i] == 1)
        {
            bMedievalModeAllowed = true;
            break;
        }
    }
    return bMedievalModeAllowed;
}

static bool IsDefinitionAllowedInMedievalMode(definition_t def, TFClassType class)
{
    if (GameRules_GetProp("m_bPlayingMedieval", 1))
    {
        if (def.m_iAllowedInMedieval == 0)
            return false;
        if (def.m_iAllowedInMedieval == -1 && !AllowedOnMedievalByDefault(def.m_iItemDef, class))
            return false;
    }
    return true;
}

static bool IsDefinitionAllowed(definition_t def, TFClassType class, int slot)
{
    if (!IsDefinitionAllowedInMedievalMode(def, class))
        return false;
    if (def.GetSlot(class, LoadoutToTF2(slot, class)))
        return true;
    if (!g_bBlockUnlisted && TF2Econ_GetItemLoadoutSlot(def.m_iItemDef, class) == LoadoutToTF2(slot, class))
        return true;
    return false;
}

static int CreateFakeWearable()
{
    int wearable = CreateEntityByName("tf_wearable");
    SetEntProp(wearable, Prop_Send, "m_bInitialized", true);
    DispatchSpawn(wearable);
    RemoveEntity(wearable);
    return wearable;
}

static int CreateFakeWeapon()
{
    int weapon = CreateEntityByName("tf_weapon_bat");
    SetEntProp(weapon, Prop_Send, "m_bInitialized", true);
    DispatchSpawn(weapon);
    RemoveEntity(weapon);
    return weapon;
}

static int CalculateItemDefFromSectionName(char arg[64])
{
    int itemdef = RetrieveItemDefByName(arg);
    if (itemdef != TF_ITEMDEF_DEFAULT)
        return itemdef;
    
    char buffer[68];
    Format(buffer, sizeof(buffer), "The %s", arg);
    itemdef = RetrieveItemDefByName(buffer);
    if (itemdef != TF_ITEMDEF_DEFAULT)
        return itemdef;

    // If still invalid, the section might be an itemdef itself?
    if (itemdef == TF_ITEMDEF_DEFAULT)
    {
        itemdef = StringToInt(arg);
        if (EqualsZero(arg) || (0 < itemdef <= 0xFFFF))
            TF2Econ_GetItemName(itemdef, arg, sizeof(arg));
        else
            itemdef = TF_ITEMDEF_DEFAULT;
    }
    return itemdef;
}

static bool GiveTo(int client, int slot, char name[NAME_LENGTH], bool persist, int iscmd = -1)
{
    // Get player data.
    PlayerData data = PlayerData(client);
    if (data.m_eClass == TFClass_Unknown)
        return false;
    Inventory inventory = data.GetInventory();

    // If no definition for the name exists, return false.
    Definition definition = ResolveDefinitionByName(name);
    if (definition == NULL_DEFINITION)
        return false;

    // Get the definition_t enum struct and confirm the slot. If the slot is
    // invalid, throw an error.
    definition_t def;
    definition.Get(def);
    if (!def.GetSlot(data.m_eClass, LoadoutToTF2(slot, data.m_eClass)))
    {
        if (iscmd == -1)
            ThrowNativeError(SP_ERROR_NATIVE, "[Weapon Manager]: Definition \"%s\" is not allowed on slot %i for class %i!", name, slot, data.m_eClass);
        else
            ReplyToCommand(iscmd, "[Weapon Manager]: Definition \"%s\" is not allowed on slot %i for class %i!", name, slot, data.m_eClass);
        return false;
    }

    // Skip if this is not a valid definition.
    if (def.m_iItemDef == TF_ITEMDEF_DEFAULT && strlen(def.m_szCWXUID) == 0)
        return false;

    // Set this weapon through the slot methodmap and mark it as temporary.
    Slot slotdata = inventory.GetSlot(slot);
    ItemsMatchClearup(slotdata, def.m_iItemDef);
    slotdata.m_bTemporary = !persist;
    slotdata.m_Selected = definition; 

    // Check if this is a CWX weapon. If so, handle it here.
    if (strlen(def.m_szCWXUID) > 0 && g_LoadedCWX)
    {
        CWX_EquipPlayerItem(client, def.m_szCWXUID);
        if (persist)
            CWX_SetPlayerLoadoutItem(client, data.m_eClass, def.m_szCWXUID, LOADOUT_FLAG_UPDATE_BACKEND);
        return true;
    }

    // Create the weapon.
    char classname[ENTITY_NAME_LENGTH];
    int entity, ammotype;
    bool iswearable, correctSlot;
    bool created = slotdata.CreateNewWeapon(iswearable, correctSlot, entity, ammotype, classname);
    if (!created)
        return false;

    // Equip the wearable or queue the weapon.
    if (iswearable)
    {
        // Before we do anything else, we actually have to set this to true so that
        // CTFPlayer::ValidateWearables() does not delete wearables spawned here!
        if (slot < WEAPONS_LENGTH)
            SetEntData(entity, CTFWearable_m_bAlwaysAllow, true, 1);
        
        // Spawn the wearable.
        SDKCall(SDKCall_CTFPlayer_EquipWearable, client, entity);
    }
    else
    {
        // Equipping weapons are delayed until the end of loadout construction.
        // This is because of an issue with equipping multiple custom slot weapons in 
        // one inventory, where one weapon may always be equipped regardless of the 
        // slot chosen.
        if (correctSlot)
            g_PlayerData[client].m_ToEquip[g_PlayerData[client].m_iEquipIndex++] = entity;
        else
            g_PlayerData[client].m_ToEquipLast[g_PlayerData[client].m_iLastEquipIndex++] = EntIndexToEntRef(entity);
    }

    // Create the fake slot replacement entity if needed and equip it.
    if (!iswearable && !correctSlot)
        slotdata.CreateFakeSlotReplacement(entity, ammotype, classname);

    // Clear equip backlog.
    for (int i = 0; i < g_PlayerData[client].m_iEquipIndex; ++i)
        EquipPlayerWeapon(client, g_PlayerData[client].m_ToEquip[i]);
    ClearEquipLastBacklog(client);
    g_PlayerData[client].m_iEquipIndex = 0;

    // Set the ammo of the newly equipped weapon if it uses a fake slot replacement entity.
    int replacement = EntRefToEntIndex(slotdata.m_hReplacement);
    int type = GetEntProp(replacement, Prop_Send, "m_iPrimaryAmmoType");
    if (IsValidEntity(slotdata.m_hFakeSlotReplacement) && TF_AMMO_PRIMARY <= g_EntityData[replacement].m_iPrimaryAmmoType < TF_AMMO_COUNT && 0 <= type < MAX_AMMO_SLOTS)
        SetEntProp(client, Prop_Send, "m_iAmmo", GetMaxAmmo(client, type, data.m_eClass), .element = type);

    // Fix ammo for the newly equipped weapon.
    RequestFrame(FixAmmo, slotdata);

    // Equip a designated slot if requested.
    if (g_PlayerData[client].m_iSlotToEquip != -1)
    {
        if (IsValidEntity(slotdata.m_hReplacement))
            SetEntPropEnt(client, Prop_Send, "m_hActiveWeapon", slotdata.m_hReplacement);
        g_PlayerData[client].m_iSlotToEquip = -1;
    }

    // Cache the current loadout.
    inventory.CacheCurrentLoadout();

    // Return to command.
    return true;
}

static bool GiveToNext(int client, TFClassType class, int slot, char name[NAME_LENGTH], int iscmd = -1)
{
    // If no definition for the name exists, return false.
    Definition definition = ResolveDefinitionByName(name);
    if (definition == NULL_DEFINITION)
        return false;

    // Get the definition_t enum struct and confirm the slot. If the slot is
    // invalid, throw an error.
    definition_t def;
    definition.Get(def);
    if (!def.GetSlot(class, LoadoutToTF2(slot, class)))
    {
        if (iscmd == -1)
            ThrowNativeError(SP_ERROR_NATIVE, "[Weapon Manager]: Definition \"%s\" is not allowed on slot %i for class %i!", name, slot, class);
        else
            ReplyToCommand(iscmd, "[Weapon Manager]: Definition \"%s\" is not allowed on slot %i for class %i!", name, slot, class);
        return false;
    }

    // Skip if this is not a valid definition.
    if (def.m_iItemDef == TF_ITEMDEF_DEFAULT && strlen(def.m_szCWXUID) == 0)
        return false;

    // Get player data and equip this definition!
    PlayerData data = PlayerData(client);
    Inventory inventory = data.GetInventory(class);
    Slot slotdata = inventory.GetSlot(slot);
    slotdata.m_bTemporary = false;
    slotdata.m_Selected = definition;

    // Cache the current loadout.
    inventory.CacheCurrentLoadout();

    // Return to command.
    return true;
}

static bool RemovePersist(int client, TFClassType class, int slot)
{
    // Get player data, unequip the definition and return to command.
    PlayerData data = PlayerData(client);
    Inventory inventory = data.GetInventory(class);
    Slot slotdata = inventory.GetSlot(slot);
    if (slotdata.m_Selected == NULL_DEFINITION)
        return false;
    slotdata.m_Selected = NULL_DEFINITION;
    return true;
}

static int GetCEconItemViewItemDefinitionIndex(any m_Item)
{
    // Cache the offset for m_iItemDefinitionIndex.
    static int m_iItemDefinitionIndex = 0;
    if (!m_iItemDefinitionIndex)
        m_iItemDefinitionIndex = FindSendPropInfo("CEconEntity", "m_iItemDefinitionIndex") - FindSendPropInfo("CEconEntity", "m_Item");

    // Return TF_ITEMDEF_DEFAULT if the address is nullptr.
    if (!m_Item)
        return TF_ITEMDEF_DEFAULT;
    
    // Return the item definition index.
    return LoadFromAddress(m_Item + m_iItemDefinitionIndex, NumberType_Int16);
}

// Post-call CEconEntity::Spawn().
// If there is a valid definition for this weapon and it is allowed on medieval mode,
// give it its attribute.
static void CEconEntity_Spawn_Post(int entity)
{
    // Check the validity of this weapon.
    if (!IsValidEntity(entity))
        return;

    // Get the definition for this entity.
    if (!HasEntProp(entity, Prop_Send, "m_iItemDefinitionIndex"))
        return;
    int itemdef = GetEntProp(entity, Prop_Send, "m_iItemDefinitionIndex");
    if (!g_DefinitionsByIndex[itemdef].m_bToggled)
        return;
    definition_t def;
    view_as<Definition>(g_DefinitionsByIndex[itemdef].m_Object).Get(def);

    // Check if it is allowed on medieval mode. If so, give it its attributes.
    if (def.m_iAllowedInMedieval == 1)
        TF2Attrib_SetByName(entity, "allowed in medieval mode", 1.00);
}

//////////////////////////////////////////////////////////////////////////////
// EVENT CODE                                                               //
//////////////////////////////////////////////////////////////////////////////

static void post_inventory_application(Event event, const char[] name, bool dontBroadcast)
{
    // Get the client.
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (!IsValidEntity(client) || !(1 <= client <= MaxClients))
        return;

    // If told, force player re-generation.
    if (g_PlayerData[client].m_bForceRegeneration)
    {
        g_PlayerData[client].m_bForceRegeneration = false;
        TF2_RegeneratePlayer(client);
    }

    // Get player data.
    PlayerData data = PlayerData(client);
    Inventory inventory = data.GetInventory();

    // Go through each weapon and correct the ammo.
    for (int i = 0; i < WEAPONS_LENGTH; ++i)
    {
        // Get each weapon.
        Slot slot = inventory.GetSlot(i);
        int weapon = EntRefToEntIndex(slot.m_hReplacement);
        if (!IsValidEntity(weapon))
            continue;
        if (!HasEntProp(weapon, Prop_Send, "m_iPrimaryAmmoType"))
            continue;
        
        // Check if it has modified ammo types.
        int primary = GetEntProp(weapon, Prop_Send, "m_iPrimaryAmmoType");
        if (TF_AMMO_PRIMARY <= g_EntityData[weapon].m_iPrimaryAmmoType < TF_AMMO_COUNT && 0 <= primary < MAX_AMMO_SLOTS)
            SetEntProp(client, Prop_Send, "m_iAmmo", GetMaxAmmo(client, primary, data.m_eClass), .element = primary);

        // NOTE:
        // Yes, I'm aware that the ammo attributes are fucked. 
        // I'll probably work on custom attributes with a secondary plugin at some point.
        // I'll have to also consider weapons like the Gas Passer and Thermal Thruster,
        // which do not work completely well when weapons using custom slots are
        // involved.
    }
}

//////////////////////////////////////////////////////////////////////////////
// CONVAR CODE                                                              //
//////////////////////////////////////////////////////////////////////////////

static void MedievalModeToggled(ConVar convar, const char[] oldValue, const char[] newValue)
{
    // If Medieval Mode is toggled, we have to refresh loadouts.
    if (convar.BoolValue)
    {
        GameRules_SetProp("m_bPlayingMedieval", true, 1);
        ParseDefinitions(g_szCurrentPath);
    }
    else
        GameRules_SetProp("m_bPlayingMedieval", false, 1);
}

//////////////////////////////////////////////////////////////////////////////
// FORWARDS                                                                 //
//////////////////////////////////////////////////////////////////////////////

public void OnGameFrame()
{
    for (int client = 1; client <= MaxClients; ++client)
    {
        // Validate the client.
        if (!IsClientInGame(client))
            return;

        // Get player data.
        PlayerData data = PlayerData(client);
        Inventory inventory = data.GetInventory();
        int active = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
        
        // Go through each weapon slot.
        for (int i = 0; i < WEAPONS_LENGTH; ++i)
        {
            // Verify replacement entity.
            Slot slot = inventory.GetSlot(i);
            if (!IsValidEntity(slot.m_hReplacement) || !IsValidEntity(slot.m_hFakeSlotReplacement))
                continue;

            // Skip if either entities are the world.
            if (!slot.m_hReplacement || !slot.m_hFakeSlotReplacement)
                continue;
            
            // Set the fake slot replacement's ammo to 0 if the actual weapon's ammo is 0.
            int clip = GetEntProp(slot.m_hReplacement, Prop_Send, "m_iClip1");
            if ((GetEntProp(client, Prop_Send, "m_iAmmo", .element = UNUSED_SLOT + i) == 0) && (TF_AMMO_PRIMARY <= g_EntityData[EntRefToEntIndex(slot.m_hReplacement)].m_iPrimaryAmmoType < TF_AMMO_COUNT) && ((clip == 255) || (clip == 0)))
            {
                SetEntProp(slot.m_hFakeSlotReplacement, Prop_Send, "m_iClip1", 0);
                SetEntProp(client, Prop_Send, "m_iAmmo", 0, .element = UNUSED_SLOT + WEAPONS_LENGTH + i);
            }
            else
            {
                SetEntProp(slot.m_hFakeSlotReplacement, Prop_Send, "m_iClip1", 6);
                SetEntProp(client, Prop_Send, "m_iAmmo", 2, .element = UNUSED_SLOT + WEAPONS_LENGTH + i);
            }

            // If the player for some reason has the fake slot replacement entity equipped, trigger the
            // hook for Weapon_Switch.
            if (IsValidEntity(active) && EntIndexToEntRef(active) == slot.m_hFakeSlotReplacement)
            {
                SetEntPropEnt(client, Prop_Send, "m_hActiveWeapon", slot.m_hReplacement);
                SDKCall(SDKCall_CBaseCombatWeapon_Deploy, slot.m_hReplacement);
            }
        }
    }
}

//////////////////////////////////////////////////////////////////////////////
// CONFIG PARSER                                                            //
//////////////////////////////////////////////////////////////////////////////

static bool EqualsZero(const char[] value)
{
    bool foundPeriod = false;
    int size = strlen(value);
    if (size == 0)
        return false;
    
    for (int i = 0; i < size; ++i)
    {
        if (value[i] == '.')
        {
            if (foundPeriod)
                return false;
            foundPeriod = true;
            continue;
        }
        if (value[i] != '0')
            return false;
    }
    return true;
}

static void ParseDefinitions(const char[] path)
{   
    // Clear loadouts.
    for (int client = 1; client <= MaxClients; ++client)
    {
        if (IsClientInGame(client))
        {
            for (TFClassType class = TFClass_Unknown; class <= TFClass_Engineer; ++class)
                PlayerData(client).GetInventory(class).Clear();
        }
    }

    // Clear default definitions list.
    for (int x = 0; x < sizeof(g_DefaultDefinitionBuffers); ++x)
    {
        for (int y = 0; y < sizeof(g_DefaultDefinitionBuffers[]); ++y)
        {
            g_DefaultDefinitionBuffers[x][y] = "";
            g_DefaultDefinitions[x][y] = NULL_DEFINITION;
        }
    }

    // Disable the by-index list.
    for (int i = 0; i < sizeof(g_DefinitionsByIndex); ++i)
        g_DefinitionsByIndex[i].m_bToggled = false;

    // Clear existing list.
    g_Definitions.Clear();
    if (g_DefinitionsSnapshot)
        delete g_DefinitionsSnapshot;

    // Section A: parse through the currently desired definitions config.
    bool cwx_warning = false;
    if (FileExists(path, true))
    {
        KeyValues kv = new KeyValues("Loadout");
        kv.ImportFromFile(path);
        
        PrintToServer("Parsing global options at \"%s\":", path);
        g_bLoadDefaults = view_as<bool>(kv.GetNum("#loaddefaults", 1));
        g_bWhitelist = view_as<bool>(kv.GetNum("#whitelist", 0));
        g_bFilterBotkiller = view_as<bool>(kv.GetNum("#filterbotkiller", 1));
        g_bFilterFestive = view_as<bool>(kv.GetNum("#filterfestive", 1));
        g_bBlockUnlisted = view_as<bool>(kv.GetNum("#blockunlisted", 1));
        g_bCreateMiscDefs = view_as<bool>(kv.GetNum("#createmiscdefs", 1));
        PrintToServer("- #loaddefaults: %s", (g_bLoadDefaults ? "true" : "false"));
        PrintToServer("- #whitelist: %s", (g_bWhitelist ? "true" : "false"));
        PrintToServer("- #filterbotkiller: %s", (g_bFilterBotkiller ? "true" : "false"));
        PrintToServer("- #filterfestive: %s", (g_bFilterFestive ? "true" : "false"));
        PrintToServer("- #blockunlisted: %s", (g_bBlockUnlisted ? "true" : "false"));
        PrintToServer("- #createmiscdefs: %s", (g_bCreateMiscDefs ? "true" : "false"));
        PrintToServer("");
        
        PrintToServer("Parsing definitions at \"%s\".", path);
        if (kv.GotoFirstSubKey(true))
        {
            char section[NAME_LENGTH];
            do
            {
                // Verify the section name.
                kv.GetSectionName(section, sizeof(section));
                TrimString(section);
                if (strcmp(section, "NULL", false) == 0)
                    ThrowError("[Weapon Manager]: Cannot create a definition called NULL!");
                if (section[0] == '#')
                    continue;

                // Attempt to retrieve the item definition index from the section name.
                int itemdef = CalculateItemDefFromSectionName(section);

                // Throw an error if the definition already exists.
                if (DefinitionExists(section, itemdef))
                    ThrowError("[Weapon Manager]: Cannot create definition %s as it, or the item definition index of another definition, already exists!", section);

                // Create the definition and check if there is a definition to inherit data from.
                char inherits_string[NAME_LENGTH];
                kv.GetString("#inherits", inherits_string, sizeof(inherits_string));
                TrimString(inherits_string);
                definition_t inherits_def;
                definition_t def;
                CreateDefinition(def, section, itemdef);
                def.m_bAutomaticallyConfigured = false;
                if (FindDefinition(inherits_def, inherits_string))
                {
                    strcopy(def.m_szClassName, sizeof(def.m_szClassName), inherits_def.m_szClassName);
                    strcopy(def.m_szCWXUID, sizeof(def.m_szCWXUID), inherits_def.m_szCWXUID);
                    def.m_ClassInformation = inherits_def.m_ClassInformation;
                    def.m_bDefault = inherits_def.m_bDefault;
                }

                // Parse basic data for the definition.
                def.m_bSave = true;
                def.m_bShowInLoadout = !!(kv.GetNum("#visible", 1));
                def.m_iAllowedInMedieval = (kv.GetNum("#medieval", -1));
                def.m_bDefault = !!((kv.GetNum("#default", -1) == -1) ? view_as<int>(def.m_bDefault) : kv.GetNum("#default"));
                kv.GetString("#iscwx", def.m_szCWXUID, sizeof(def.m_szCWXUID));
                if (strlen(def.m_szCWXUID) > 0)
                    cwx_warning = true;
                else
                {
                    char tempclass[ENTITY_NAME_LENGTH];
                    kv.GetString("#classname", tempclass, sizeof(tempclass));
                    if (strlen(tempclass) > 0)
                        strcopy(def.m_szClassName, sizeof(def.m_szClassName), tempclass);
                    else if (def.m_iItemDef != TF_ITEMDEF_DEFAULT)
                        TF2Econ_GetItemClassName(def.m_iItemDef, def.m_szClassName, sizeof(def.m_szClassName));
                }

                // Get slot information.
                // class1 x y z; class2 x y z;
                char slotbuffer[320];
                char slots[view_as<int>(TFClass_Engineer) + 1][32];
                kv.GetString("#classes", slotbuffer, sizeof(slotbuffer), "-EMPTY-");
                TrimString(slotbuffer);

                // Check to see if we should toggle EVERY slot.
                if (strcmp(slotbuffer, "all") == 0)
                {
                    for (TFClassType class = TFClass_Scout; class <= TFClass_Engineer; ++class)
                    {
                        for (int i = 0; i < WEAPONS_LENGTH; ++i)
                            def.SetSlot(class, LoadoutToTF2(i, class), true);
                    }
                }
                else if (strlen(slotbuffer) > 0 && strcmp(slotbuffer, "-EMPTY-") != 0)
                {
                    for (int i = 0, size = ExplodeString(slotbuffer, ";", slots, sizeof(slots), sizeof(slots[])); i < size; ++i)
                    {
                        char class_slot[MAX_SLOTS + 1][16];
                        TFClassType class = TFClass_Unknown;
                        TrimString(slots[i]);
                        for (int i2 = 0, size2 = ExplodeString(slots[i], " ", class_slot, sizeof(class_slot), sizeof(class_slot[])); i2 < size2; ++i2)
                        {
                            // NULL check.
                            if (strlen(class_slot[i2]) == 0)
                                break;
                            
                            // Get class specified.
                            if (i2 == 0)
                            {
                                if (!g_Classes.GetValue(class_slot[i2], class))
                                    ThrowError("[Weapon Manager]: Could not find class %s in definition %s", class_slot[i2], section);
                            }

                            // Do we default to the intended slot for this definition?
                            int slotUsed;
                            if (size2 == 1 && def.m_iItemDef != TF_ITEMDEF_DEFAULT)
                            {
                                slotUsed = TF2Econ_GetItemLoadoutSlot(def.m_iItemDef, class);
                                def.SetSlot(class, slotUsed, true);
                            }
                            else if (i2 > 0)
                            {
                                // Throw an error if:
                                // - Slot numbers is 7 (this is unused) or outside the range of 0 <= x < MAX_SLOTS
                                // - Slot number is 8 and this is a CWX definition
                                // - The slot number is not the default for this class AND it is a stock weapon.
                                slotUsed = StringToInt(class_slot[i2]);
                                if (slotUsed == 7 || slotUsed >= MAX_SLOTS || slotUsed < 0)
                                    ThrowError("[Weapon Manager]: Slot %i is invalid in definition %s", slotUsed, section);
                                else if (slotUsed == 8 && strlen(def.m_szCWXUID) > 0)
                                    ThrowError("[Weapon Manager]: Cannot assign a CWX weapon at definition %s to slot 8 (cosmetic)!", section);
                                
                                // Write to slot.
                                def.SetSlot(class, slotUsed, true);
                            }

                            // Write as the current default slot if specified.
                            if (def.m_bDefault && (size2 == 1 || i2 > 0) && IsDefinitionAllowed(def, class, slotUsed))
                            {
                                if (strlen(g_DefaultDefinitionBuffers[class][slotUsed]) > 0)
                                {
                                    definition_t oldDefault;
                                    if (FindDefinition(oldDefault, g_DefaultDefinitionBuffers[class][slotUsed]))
                                        oldDefault.m_bActualDefault = false;
                                }
                                strcopy(g_DefaultDefinitionBuffers[class][slotUsed], sizeof(g_DefaultDefinitionBuffers[][]), section);
                                def.m_bActualDefault = true;
                            }
                        }
                    }
                }
                else if (TF2Econ_IsValidItemDefinition(def.m_iItemDef) && strcmp(slotbuffer, "-EMPTY-") == 0)
                {
                    // Just default to the usual slots.
                    for (TFClassType class = TFClass_Scout; class <= TFClass_Engineer; ++class)
                    {
                        int slot = TF2Econ_GetItemLoadoutSlot(def.m_iItemDef, class);
                        if (slot != -1)
                            def.SetSlot(class, slot, true);
                    }
                }

                // Push to g_Definitions.
                def.PushToArray();
                
                // Debug information printed to the user.
                char iteminfo[64];
                if (strlen(def.m_szCWXUID) > 0)
                    Format(iteminfo, sizeof(iteminfo), "CWX UID: %s", def.m_szCWXUID);
                else
                    Format(iteminfo, sizeof(iteminfo), "item definition index: %i", def.m_iItemDef);
                PrintToServer("Parsed definition %s (%s)", section, iteminfo);

                // Check if the item definition index is valid to do any final few manipulations.
                if (def.m_iItemDef != TF_ITEMDEF_DEFAULT)
                    g_DefinitionsByIndex[def.m_iItemDef].m_bToggled = true;
            }
            while (kv.GotoNextKey(true));
        }

        delete kv;
        PrintToServer("");
    }

    // Section B: walk through all default TF2 items and write them to the definitions list.
    if (g_bLoadDefaults)
    {
        PrintToServer("Parsing internal definitions...");
        static ArrayList list;
        if (!list)
            list = TF2Econ_GetItemList();

        for (int i = 0, size = list.Length; i < size; ++i)
        {
            // Get itemdef/name info.
            char stockName[NAME_LENGTH];
            char buffer[NAME_LENGTH];
            int itemdef = list.Get(i);
            bool showInLoadout = true;
            TF2Econ_GetItemName(itemdef, buffer, sizeof(buffer));
            if (g_StockWeaponNames.GetString(buffer, stockName, sizeof(stockName)))
                strcopy(buffer, sizeof(buffer), stockName);

            // Check if there already exists a definition.
            if (DefinitionExists(buffer, itemdef))
                continue;

            // Basic item filtering.
            if (g_bFilterBotkiller && StrContains(buffer, "Botkiller") != -1)
                showInLoadout = false;
            else if (g_bFilterFestive && StrContains(buffer, "Festive") != -1)
                showInLoadout = false;
            else if (StrContains(buffer, "Promo") != -1)
                showInLoadout = false;
            else if (StrContains(buffer, "_") != -1)
                showInLoadout = false;
            else if (StrContains(buffer, "MvM") != -1)
                showInLoadout = false;
            else if (strcmp(buffer, "Deflector") == 0)
                showInLoadout = false;
            if (!showInLoadout && !g_bCreateMiscDefs)
                continue;
            bool skip = true;
            for (TFClassType class = TFClass_Scout; class <= TFClass_Engineer; ++class)
            {
                int slot = TF2Econ_GetItemLoadoutSlot(itemdef, class);
                if (-1 < slot < 9)
                {
                    skip = false;
                    break;
                }
            }
            if (skip)
                continue;

            // Create a new definition and write basic information.
            definition_t def;
            CreateDefinition(def, buffer, itemdef);
            def.m_bAutomaticallyConfigured = true;
            def.m_bSave = false;
            def.m_szCWXUID = "";
            def.m_bShowInLoadout = showInLoadout;
            def.m_iAllowedInMedieval = -1;
            TF2Econ_GetItemClassName(itemdef, def.m_szClassName, sizeof(def.m_szClassName));

            // Write class/slot information.
            for (TFClassType class = TFClass_Scout; class <= TFClass_Engineer; ++class)
            {
                // Get the slot used for this weapon.
                // ALWAYS set it to true if this is a stock weapon.
                // Otherwise, only set it to true if g_bWhitelist == false.
                int slot = TF2Econ_GetItemLoadoutSlot(itemdef, class);
                bool isvanilla = TF2Econ_IsItemInBaseSet(itemdef) || (9 <= itemdef <= 12);
                if (slot == -1)
                    continue;
                if (isvanilla || !g_bWhitelist)
                    def.SetSlot(class, slot, true);

                // If this is a stock weapon, set as default if not already specified.
                if (isvanilla && strlen(g_DefaultDefinitionBuffers[class][slot]) == 0)
                {
                    def.m_bActualDefault = true;
                    strcopy(g_DefaultDefinitionBuffers[class][slot], sizeof(g_DefaultDefinitionBuffers[][]), buffer);
                }
            }

            // Push to g_Definitions.
            def.PushToArray();

            // Debug information printed to the user (if requested).
            if (g_bPrintAllDefs)
                PrintToServer("Parsed internal definition %s (item definition index: %i)", buffer, itemdef);
                
            // Toggle this in the by-index list.
            g_DefinitionsByIndex[def.m_iItemDef].m_bToggled = true;
        }
    }
    else
        PrintToServer("g_bLoadDefaults is false, not parsing internal definitions...");

    // Make a snapshot of g_Definitions.   
    g_DefinitionsSnapshot = g_Definitions.Snapshot();
    for (Definition it = Definition.begin(); it != Definition.end(); ++it)
    {
        // Write to g_DefinitionsByIndex.
        definition_t def;
        it.Get(def);
        if (def.m_iItemDef != TF_ITEMDEF_DEFAULT)
            g_DefinitionsByIndex[def.m_iItemDef].m_Object = it;

        // Write to g_DefaultDefinitions. God this code is fucking stupid.
        if (def.m_bActualDefault)
        {
            for (TFClassType class = TFClass_Scout; class <= TFClass_Engineer; ++class)
            {
                for (int slot = 0; slot < MAX_SLOTS; ++slot)
                {
                    if (IsDefinitionAllowed(def, class, slot))
                        g_DefaultDefinitions[class][slot] = it;
                }
            }
        }
    }

    // Call AttributeManager_OnDefinitionsLoaded().
    Call_StartForward(g_LoadedDefinitionsForward);
    Call_PushCell(false);
    Call_Finish();

    // Error.
    if (cwx_warning && !g_LoadedCWX)
        PrintToServer("[Weapon Manager]: WARNING! CUSTOM WEAPONS X IS NOT LOADED, HOWEVER DEFINITIONS WHICH RELY ON CWX HAVE BEEN FOUND!");
}

//////////////////////////////////////////////////////////////////////////////
// ECON                                                                     //
//////////////////////////////////////////////////////////////////////////////

// Convert a string to lower case.
void StringToLower(const char[] buffer, char[] output, int maxlength)
{
	for (int i = 0; i < maxlength; ++i)
	{
		if (buffer[i] == 0)
		{
			output[i] = 0;
			break;
		}
		output[i] = CharToLower(buffer[i]);
	}
}

// Retrieve the item definition index of a weapon by its internal name.
static int RetrieveItemDefByName(const char[] name)
{
    static StringMap definitions;
    if (definitions)
    {
        int value = TF_ITEMDEF_DEFAULT;
        char buffer[NAME_LENGTH];
        strcopy(buffer, sizeof(buffer), name);
        StringToLower(buffer, buffer, sizeof(buffer));
        return (definitions.GetValue(buffer, value) ? value : TF_ITEMDEF_DEFAULT);
    }

    definitions = new StringMap();
    ArrayList list = TF2Econ_GetItemList();
    char buffer[NAME_LENGTH];
    for (int i = 0, size = list.Length; i < size; ++i)
    {
        // Retrieve buffer.
        int itemdef = list.Get(i);
        TF2Econ_GetItemName(itemdef, buffer, sizeof(buffer));

        // Convert to visible name if specified.
        char stockName[NAME_LENGTH];
        if (g_StockWeaponNames.GetString(buffer, stockName, sizeof(stockName)))
        {
            StringToLower(stockName, stockName, sizeof(stockName));
            definitions.SetValue(stockName, itemdef);
        }

        // Convert to lower case and write.
        StringToLower(buffer, buffer, sizeof(buffer));
        definitions.SetValue(buffer, itemdef);

        // Also add by adding "The" to the start.
        Format(buffer, sizeof(buffer), "the %s", buffer);
        definitions.SetValue(buffer, itemdef);
    }
    delete list;
    
    // Add a few special cases.
    definitions.SetValue("The Shotgun", 9);
    definitions.SetValue("The Pistol", 22);

    return RetrieveItemDefByName(name);
}

//////////////////////////////////////////////////////////////////////////////
// DETOURS                                                                  //
//////////////////////////////////////////////////////////////////////////////

// Post-call CTFPlayer::GetLoadoutItem().
// Originally we were using CTFPlayer::ItemsMatch(), but that is hilariously broken on
// Linux for some reason...
// Supercede the call and return our replacement weapon if it is valid.
MRESReturn CTFPlayer_GetLoadoutItem(int client, DHookReturn returnValue, DHookParam parameters)
{
    // Get player's inventory.
    PlayerData data = PlayerData(client);
    Inventory inventory = data.GetInventory();

    // Cache the offset for m_Item.
    static any m_Item;
    if (!m_Item)
        m_Item = FindSendPropInfo("CEconEntity", "m_Item");

    // Retrieve the item definition index of the new m_Item object.
    if (!returnValue.Value)
        return MRES_Ignored;
    int itemdef = GetCEconItemViewItemDefinitionIndex(returnValue.Value);

    // Get the slot from the new item definition. If it's invalid, fall back on the weapon for the current slot.
    int itemdefSlot = TF2Econ_GetItemLoadoutSlot(itemdef, data.m_eClass);
    if (itemdefSlot < 0 || itemdefSlot > 6)
        return MRES_Ignored;
    Slot slot = inventory.GetSlot(TF2ToLoadout(itemdefSlot, data.m_eClass));

    // Skip completely if there is a CWX weapon in this slot.
    char uid[NAME_LENGTH];
    if (g_LoadedCWX && CWX_GetPlayerLoadoutItem(client, data.m_eClass, itemdefSlot, uid, sizeof(uid)))
    {
        ItemsMatchClearup(slot, itemdef);
        return MRES_Ignored;
    }

    // Check this itemdef's slot and see if it is being used.
    if (slot.m_Prioritised == NULL_DEFINITION)
    {
        ItemsMatchClearup(slot, itemdef);
        return MRES_Ignored;
    }
    if (slot.m_Cached != slot.m_Prioritised)
    {
        ItemsMatchClearup(slot, itemdef);
        return MRES_Ignored;
    }

    // Invalidate this slot completely if it is a selected slot and was temporary.
    if (slot.m_Prioritised == slot.m_Selected && slot.m_bTemporary)
    {
        ItemsMatchClearup(slot, itemdef);
        return MRES_Ignored;
    }

    // Check if we don't have anything selected and the weapon is instead being inhibited.
    // In this scenario, we have to compare the item definitions of the inhibited weapon
    // and the new weapon's m_Item.
    if (slot.m_Selected == NULL_DEFINITION)
    {
        definition_t inhibited;
        slot.m_Inhibited.Get(inhibited);
        if (inhibited.m_iItemDef != itemdef)
        {
            // Is this definition allowed? If so, ignore this detour.
            definition_t newItem;
            Definition.FromItemDefinitionIndex(itemdef).Get(newItem);
            if (newItem.m_iItemDef != TF_ITEMDEF_DEFAULT && IsDefinitionAllowed(newItem, data.m_eClass, itemdefSlot))
            {
                ItemsMatchClearup(slot, itemdef);
                return MRES_Ignored;
            }

            // Check if the default weapon definition matches with the current weapon.
            if (slot.m_Inhibited != slot.m_Default)
            {
                ItemsMatchClearup(slot, itemdef);
                slot.m_Inhibited = slot.m_Default;
                return MRES_Ignored;
            }
        }
    }

    // This weapon is a valid replacement and we should be returning that m_Item instead.
    // If our replacement entity doesn't exist yet, spawn a fake wearable temporarily and
    // use the m_Item of that because we cannot return a null pointer.
    if (IsValidEntity(slot.m_hReplacement))
        returnValue.Value = GetEntityAddress(slot.m_hReplacement) + m_Item;
    else
        returnValue.Value = GetEntityAddress(CreateFakeWearable()) + m_Item;
    return MRES_Supercede;
}

// Pre-call CTFPlayer::ManageRegularWeapons().
// Weapon code is completely fine with the above detour, however wearables aren't fully
// catched into it. We need to force wearables to always stay alive internally and delete
// it ourselves here.
//
// Also, in the case that this is a weapon that is not designated for the desired class
// whatsoever, we need to fake its item definition index.
//
// If the weapon is in the wrong slot, the entity classname must be faked too!
MRESReturn CTFPlayer_ManageRegularWeapons_Pre(int client, DHookParam parameters)
{
    // Get player's inventory.
    PlayerData data = PlayerData(client);
    Inventory inventory = data.GetInventory();

    // Go through each slot.
    for (int i = 0; i < WEAPONS_LENGTH; ++i)
    {
        Slot slot = inventory.GetSlot(i);

        char uid[NAME_LENGTH];
        if (g_LoadedCWX && CWX_GetPlayerLoadoutItem(client, data.m_eClass, LoadoutToTF2(i, data.m_eClass), uid, sizeof(uid)))
            continue;

        if (slot.m_Prioritised != NULL_DEFINITION && slot.m_Cached == slot.m_Prioritised)
        {
            // Skip completely if the prioritised slot is a selected slot and it is temporary.
            if (slot.m_Prioritised == slot.m_Selected && slot.m_bTemporary)
                continue;

            // This may be a weapon that should persist on this class. Fake its item definition index.
            if (IsValidEntity(slot.m_hReplacement))
            {
                for (int item, length = g_StockItems.Length; item < length; ++item)
                {
                    int foundItemDef = g_StockItems.Get(item);
                    int foundSlot = TF2Econ_GetItemLoadoutSlot(foundItemDef, inventory.m_eClass);
                    if (foundSlot == LoadoutToTF2(i, data.m_eClass))
                    {
                        // Set the item definition indexes of the replaced weapons.
                        slot.m_iCachedItemDefinitionIndex = GetEntProp(slot.m_hReplacement, Prop_Send, "m_iItemDefinitionIndex");
                        SetEntProp(slot.m_hReplacement, Prop_Send, "m_iItemDefinitionIndex", foundItemDef);
                        if (IsValidEntity(slot.m_hFakeSlotReplacement))
                            SetEntProp(slot.m_hFakeSlotReplacement, Prop_Send, "m_iItemDefinitionIndex", foundItemDef);

                        // Set the entity classname of the real replacement weapon.
                        char buffer[64];
                        TF2Econ_GetItemClassName(foundItemDef, buffer, sizeof(buffer));
                        TranslateWeaponEntForClass(buffer, sizeof(buffer), data.m_eClass);
                        SetEntPropString(slot.m_hReplacement, Prop_Data, "m_iClassname", buffer);

                        // Set the entity quality of the real replacement weapon.
                        SetEntData(slot.m_hReplacement, FindSendPropInfo("CEconEntity", "m_iEntityQuality"), AE_UNIQUE);
    
                        // Next weapon.
                        break;
                    }
                }
            }
        }
        else
        {
            // This weapon is not for this slot anymore. Handle weapon destruction code here.
            if (IsValidEntity(slot.m_hReplacement))
            {
                char buffer[ENTITY_NAME_LENGTH];
                GetEntityClassname(slot.m_hReplacement, buffer, sizeof(buffer));
                if (StrContains(buffer, "tf_wearable") == 0)
                    slot.RemoveWeapon();
            }
        }
    }

    // Return.
    return MRES_Ignored;
}

// Post-call CTFPlayer::ManageRegularWeapons().
// If we faked any weapons' item definition indexes and entity classnames, 
// revert them.
MRESReturn CTFPlayer_ManageRegularWeapons_Post(int client, DHookParam parameters)
{
    // Get player's inventory.
    PlayerData data = PlayerData(client);
    Inventory inventory = data.GetInventory();

    // Go through each slot.
    for (int i = 0; i < WEAPONS_LENGTH; ++i)
    {
        Slot slot = inventory.GetSlot(i);

        char uid[NAME_LENGTH];
        if (g_LoadedCWX && CWX_GetPlayerLoadoutItem(client, data.m_eClass, LoadoutToTF2(i, data.m_eClass), uid, sizeof(uid)))
            continue;

        if (slot.m_Prioritised == NULL_DEFINITION)
            continue;
        
        if (slot.m_Cached != slot.m_Prioritised)
            continue;

        // Skip completely if the prioritised slot is a selected slot and it is temporary.
        if (slot.m_Prioritised == slot.m_Selected && slot.m_bTemporary)
            continue;

        // Revert this weapon's item definition index and entity classname.
        if (IsValidEntity(slot.m_hReplacement) && !(GetEntityFlags(slot.m_hReplacement) & FL_KILLME))
        {
            // Get the definition.
            definition_t def;
            slot.m_Prioritised.Get(def);
            slot.m_iCachedItemDefinitionIndex = TF_ITEMDEF_DEFAULT;

            // Revert item definition index.
            SetEntProp(slot.m_hReplacement, Prop_Send, "m_iItemDefinitionIndex", def.m_iItemDef);
            if (IsValidEntity(slot.m_hFakeSlotReplacement))
                SetEntProp(slot.m_hFakeSlotReplacement, Prop_Send, "m_iItemDefinitionIndex", def.m_iItemDef);

            // Revert entity classname.
            char classname[64];
            strcopy(classname, sizeof(classname), def.m_szClassName);
            TranslateWeaponEntForClass(classname, sizeof(classname), data.m_eClass);
            SetEntPropString(slot.m_hReplacement, Prop_Data, "m_iClassname", classname);

            // Revert the entity quality.
            SetEntData(slot.m_hReplacement, FindSendPropInfo("CEconEntity", "m_iEntityQuality"), slot.m_iEntityQuality);
        }
    }

    // Return.
    return MRES_Ignored;
}

// Pre-call CTFPlayer::ValidateWeapons().
// If we have any CWX weapons already equipped that we want to unequip, remove them here.
MRESReturn CTFPlayer_ValidateWeapons_Pre(int client, DHookParam parameters)
{
    // Check if the boolean parameter is false.
    bool bResetWeapons = parameters.Get(2);
    if (!bResetWeapons && g_LoadedCWX)
    {
        // Get the player's inventory.
        PlayerData data = PlayerData(client);
        Inventory inventory = data.GetInventory();
        inventory.SortLoadout();

        // Walk through each slot.
        for (int i = 0; i < WEAPONS_LENGTH; ++i)
        {
            // Get some basic slot information.
            Slot slot = inventory.GetSlot(i);
            int tf2Slot = LoadoutToTF2(i, data.m_eClass);
            char uid[NAME_LENGTH];
            bool selected = (slot.m_Prioritised != NULL_DEFINITION);

            // Check if a CWX weapon is already equipped.
            bool hascwxWeapon = ((g_LoadedCWX && i < WEAPONS_LENGTH) ? CWX_GetPlayerLoadoutItem(client, data.m_eClass, tf2Slot, uid, sizeof(uid)) : false);

            // Check if this slot is CWX. If so, remove it on CWX's side.
            // For some reason, while this does actually remove the weapon behind the scenes,
            // if we are relying on whatever weapon TF2 gives us, it won't spawn until the next
            // resupply, so we need to force player regeneration on post_inventory_application.
            // We cannot do that here otherwise we'll disrupt this function and the detour,
            // which will cause a crash.
            if (!selected && hascwxWeapon)
            {
                g_PlayerData[client].m_bForceRegeneration = true;
                CWX_RemovePlayerLoadoutItem(client, data.m_eClass, tf2Slot, LOADOUT_FLAG_UPDATE_BACKEND);
            }
        }
    }
    return MRES_Ignored;
}

// Post-call CTFPlayer::ValidateWeapons().
// Reconstruct our loadout here, just before the PlayerLoadoutUpdated user message is finished.
MRESReturn CTFPlayer_ValidateWeapons_Post(int client, DHookParam parameters)
{
    // Check if the boolean parameter is false.
    bool bResetWeapons = parameters.Get(2);
    if (!bResetWeapons)
    {
        PlayerData data = PlayerData(client);
        Inventory inventory = data.GetInventory();
        inventory.SortLoadout();
    }
    return MRES_Ignored;
}

// Pre-call CTFPlayer::GetMaxAmmo().
// I'm making this just so I don't have to make dumb natives for other plugin authors to use for
// this.
//
// For custom slot weapons, return the maximum ammo for them instead of some arbitrary number.
MRESReturn CTFPlayer_GetMaxAmmo(int client, DHookReturn returnValue, DHookParam parameters)
{
    // Check if this is a normal slot.
    int slot = parameters.Get(1);
    TFClassType class = parameters.Get(2);
    if (0 <= slot < TF_AMMO_COUNT)
        return MRES_Ignored;

    // Correct the class value if it is -1.
    if (class == view_as<TFClassType>(-1))
        class = TF2_GetPlayerClass(client);

    // Return the desired ammo instead.
    returnValue.Value = GetMaxAmmo(client, slot, class);
    return MRES_Supercede;
}

// Pre-call CTFPlayer::Spawn().
// This is just used to determine whether loadout reconstruction is happening during the spawn
// process or not.
MRESReturn CTFPlayer_Spawn(int client)
{
    // Do not set that the player is spawning on the player's very first spawn.
    if (g_PlayerData[client].m_bDoNotSetSpawning)
    {
        g_PlayerData[client].m_bDoNotSetSpawning = false;
        return MRES_Ignored;
    }
    g_PlayerData[client].m_bSpawning = true;

    // Go through *every* slot and clear any replacement weapons, if we swapped classes.
    PlayerData data = PlayerData(client);
    if (g_PlayerData[client].m_eLastClass != data.m_eClass)
    {
        // Walk through the list of weapons.
        for (int index = 0; index < MAX_WEAPONS; ++index)
        {
            // Get the weapon.
            int weapon = GetEntPropEnt(client, Prop_Send, "m_hMyWeapons", index);
            if (weapon == INVALID_ENT_REFERENCE)
                continue;

            // Kill the weapon.
            TF2_RemoveWeapon(client, weapon);
        }

        // Walk through the list of wearables.
        any m_hMyWearables = view_as<any>(GetEntityAddress(client)) + FindSendPropInfo("CTFPlayer", "m_hMyWearables");
        for (int index = 0, size = LoadFromAddress(m_hMyWearables + CUtlVector_m_Size, NumberType_Int32); index < size; ++index)
        {
            // Get the wearable.
            int handle = LoadFromAddress(LoadFromAddress(m_hMyWearables, NumberType_Int32) + index * 4, NumberType_Int32);
            int wearable = EntRefToEntIndex(handle | (1 << 31));
            if (wearable == INVALID_ENT_REFERENCE)
                continue;

            // Kill the wearable.
            TF2_RemoveWearable(client, wearable);
        }

        // Go through the previous class inventory to finish off any replacement entities.
        Inventory inventory = data.GetInventory(g_PlayerData[client].m_eLastClass);
        for (int i = 0; i < WEAPONS_LENGTH; ++i)
        {
            // Clear every single weapon in this slot.
            Slot slot = inventory.GetSlot(i);
            slot.RemoveWeapon();
        }

        // Cache the new class.
        g_PlayerData[client].m_eLastClass = data.m_eClass;
    }

    // Force a regeneration.
    TF2_RegeneratePlayer(client);

    // Continue.
    return MRES_Ignored;
}

// Post-call CTFAmmoPack::PackTouch().
// Refill ammo of weapons in custom slots and handle entity deletion if this pack has not been
// registered to be deleted.
MRESReturn CTFAmmoPack_PackTouch(int entity, DHookParam parameters)
{
    // Get the client who touched this pack.
    int client = parameters.Get(1);
    if (!(1 <= client <= MaxClients))
        return MRES_Ignored;
    PlayerData data = PlayerData(client);
    Inventory inventory = data.GetInventory();

    // Walk through each slot and check if there is a custom slot weapon equipped.
    bool filled = false;
    for (int i = 0; i < WEAPONS_LENGTH; ++i)
    {
        // Check that a custom slot weapon is equipped.
        Slot slot = inventory.GetSlot(i);
        if (!IsValidEntity(slot.m_hReplacement) || !IsValidEntity(slot.m_hFakeSlotReplacement))
            continue;

        // Check if this is a primary/secondary weapon.
        if (!(TF_AMMO_PRIMARY <= g_EntityData[EntRefToEntIndex(slot.m_hReplacement)].m_iPrimaryAmmoType <= TF_AMMO_SECONDARY))
            continue;

        // Check if it requires refilling ammo.
        int type = GetEntProp(slot.m_hReplacement, Prop_Send, "m_iPrimaryAmmoType");
        int max = GetMaxAmmo(client, type, data.m_eClass);
        int current = GetEntProp(client, Prop_Send, "m_iAmmo", .element = type);
        if (current < max)
        {
            filled = true;
            SetEntProp(client, Prop_Send, "m_iAmmo", min(max, current + RoundToCeil(max * 0.5)), .element = type);
        }
    }

    // Check if this pack has not been deleted. If so, handle deletion ourselves.
    if (filled && (IsValidEntity(entity) || !(GetEntityFlags(entity) & FL_KILLME)))
    {
        Event event = CreateEvent("item_pickup", true);
        event.SetInt("userid", GetClientUserId(client));
        event.SetString("item", "tf_ammo_pack");
        event.Fire();
        RemoveEntity(entity);
    }

    // Finished.
    return MRES_Ignored;
}

// Post-call CAmmoPack::MyTouch().
// Refill ammo of weapons in custom slots and handle temporary hiding if this pack has not been
// hidden.
MRESReturn CAmmoPack_MyTouch(int entity, DHookReturn returnValue, DHookParam parameters)
{
    // Get the client who touched this pack.
    int client = parameters.Get(1);
    if (!(1 <= client <= MaxClients))
        return MRES_Ignored;
    PlayerData data = PlayerData(client);
    Inventory inventory = data.GetInventory();

    // Get information about this pack.
    char classname[ENTITY_NAME_LENGTH];
    char name[32] = "ammopack_large";
    GetEntityClassname(entity, classname, sizeof(classname));
    powerupsize_t size = POWERUP_FULL;
    if (strcmp(classname, "item_ammopack_small") == 0)
    {
        size = POWERUP_SMALL;
        name = "ammopack_small";
    }
    else if (strcmp(classname, "item_ammopack_medium") == 0)
    {
        size = POWERUP_MEDIUM;
        name = "ammopack_medium";
    }
    float flPackRatio = PackRatios[size];

    // Walk through each slot and check if there is a custom slot weapon equipped.
    bool filled = false;
    for (int i = 0; i < WEAPONS_LENGTH; ++i)
    {
        // Check that a custom slot weapon is equipped.
        Slot slot = inventory.GetSlot(i);
        if (!IsValidEntity(slot.m_hReplacement) || !IsValidEntity(slot.m_hFakeSlotReplacement))
            continue;

        // Check if this is a primary/secondary weapon.
        if (!(TF_AMMO_PRIMARY <= g_EntityData[EntRefToEntIndex(slot.m_hReplacement)].m_iPrimaryAmmoType <= TF_AMMO_SECONDARY))
            continue;

        // Check if it requires refilling ammo.
        int type = GetEntProp(slot.m_hReplacement, Prop_Send, "m_iPrimaryAmmoType");
        int max = GetMaxAmmo(client, type, data.m_eClass);
        int current = GetEntProp(client, Prop_Send, "m_iAmmo", .element = type);
        if (current < max)
        {
            filled = true;
            SetEntProp(client, Prop_Send, "m_iAmmo", min(max, current + RoundToCeil(max * flPackRatio)), .element = type);
        }
    }

    // Check if this pack has not yet been made invisible. If so, handle it ourselves.
    if (filled &&!returnValue.Value)
    {
        // Create an event.
        Event event = CreateEvent("item_pickup", true);
        event.SetInt("userid", GetClientUserId(client));
        event.SetString("item", name);
        event.Fire();

        // Emit a sound to the player.
        EmitSoundToClient(client, "AmmoPack.Touch");

        // Force the ammo pack to temporarily hide.
        returnValue.Value = true;
        return MRES_Supercede;
    }

    // Finished.
    return MRES_Ignored;
}

// Post-call CObjectDispenser::DispenseAmmo().
// Refill ammo of weapons in custom slots.
MRESReturn CObjectDispenser_DispenseAmmo(int entity, DHookReturn returnValue, DHookParam parameters)
{
    // Get the client who touched this pack.
    int client = parameters.Get(1);
    if (!(1 <= client <= MaxClients))
        return MRES_Ignored;
    PlayerData data = PlayerData(client);
    Inventory inventory = data.GetInventory();

    // Get information about this dispenser.
    float flAmmoRate = g_flDispenserAmmoRates[GetEntProp(entity, Prop_Send, "m_iUpgradeLevel")];

    // Walk through each slot and check if there is a custom slot weapon equipped.
    bool filled = false;
    for (int i = 0; i < WEAPONS_LENGTH; ++i)
    {
        // Check that a custom slot weapon is equipped.
        Slot slot = inventory.GetSlot(i);
        if (!IsValidEntity(slot.m_hReplacement) || !IsValidEntity(slot.m_hFakeSlotReplacement))
            continue;

        // Check if this is a primary/secondary weapon.
        if (!(TF_AMMO_PRIMARY <= g_EntityData[EntRefToEntIndex(slot.m_hReplacement)].m_iPrimaryAmmoType <= TF_AMMO_SECONDARY))
            continue;

        // Check if it requires refilling ammo.
        int type = GetEntProp(slot.m_hReplacement, Prop_Send, "m_iPrimaryAmmoType");
        int max = GetMaxAmmo(client, type, data.m_eClass);
        int current = GetEntProp(client, Prop_Send, "m_iAmmo", .element = type);
        if (current < max)
        {
            filled = true;
            SetEntProp(client, Prop_Send, "m_iAmmo", min(max, current + RoundToCeil(max * flAmmoRate)), .element = type);
        }
    }

    // Finished.
    if (filled)
    {
        returnValue.Value = true;
        return MRES_Supercede;
    }
    return MRES_Ignored;
}

//////////////////////////////////////////////////////////////////////////////
// LOADOUT MENU                                                             //
//////////////////////////////////////////////////////////////////////////////

int CreateLoadoutMenu_Handler(Menu menu, MenuAction action, int param1, int param2)
{
    PlayerData data = PlayerData(param1);
    switch (action)
    {
        case MenuAction_End:
        {
            delete menu;
        }
        case MenuAction_Select:
        {
            // Have we selected a page?
            if (data.m_iLoadoutSlot == -1)
            {
                // Random hack to use cosmetic slots.
                /*
                //if (data.m_eClass != TFClass_Engineer && data.m_eClass != TFClass_Spy && param2 >= 3)
                //    data.m_iLoadoutSlot = (WEAPONS_LENGTH + (2 - (5 - param2)));
                //else
                    data.m_iLoadoutSlot = param2;
                */

                data.m_iLoadoutSlot = param2;
                CreateLoadoutMenu(param1);
            }
            else
            {
                // Get selected weapon buffer.
                char buffer[NAME_LENGTH];
                menu.GetItem(param2, buffer, sizeof(buffer));
                
                // Retrieve definition data.
                Definition found = Definition(StringToInt(buffer));
                definition_t def;
                found.Get(def);

                // Verify that this is the right class.
                int tf2Slot = LoadoutToTF2(data.m_iLoadoutSlot, data.m_eClass);
                if (!def.GetSlot(data.m_eClass, tf2Slot) && found != NULL_DEFINITION)
                    PrintToChat(param1, "Nice try.");
                else
                {
                    // Equip the weapon.
                    Slot slot = data.GetInventory().GetWeaponSlot(data.m_iLoadoutSlot);
                    slot.m_bTemporary = false;
                    slot.m_Selected = found;
                    PrintToChat(param1, "Make sure to hit resupply.");
                }
            }
        }
    }
    return 0;
}

void CreateLoadoutMenu(int client)
{
    // Create the menu core.
    PlayerData data = PlayerData(client);
    Inventory inventory = data.GetInventory();
    Menu menu = CreateMenu(CreateLoadoutMenu_Handler);
    menu.OptionFlags = MENUFLAG_NO_SOUND;
    menu.ExitButton = true;

    // Set up the layout of the menu.
    if (data.m_iLoadoutSlot == -1)
    {
        menu.SetTitle("Select loadout slot:");
        menu.AddItem("Primary", "Primary");
        menu.AddItem("Secondary", "Secondary");
        menu.AddItem("Melee", "Melee");
        if (data.m_eClass == TFClass_Spy)
        {
            menu.AddItem("Disguise Kit", "Disguise Kit");
            menu.AddItem("Watch", "Watch");
        }
        else if (data.m_eClass == TFClass_Engineer)
        {
            menu.AddItem("Construction PDA", "Construction PDA");
            menu.AddItem("Destruction PDA", "Destruction PDA");
        }

        // TODO: cvar
        /*
        menu.AddItem("Cosmetic 1", "Cosmetic 1");
        menu.AddItem("Cosmetic 2", "Cosmetic 2");
        menu.AddItem("Cosmetic 3", "Cosmetic 3");
        */
    }
    else
    {
        // Set up the default option.
        menu.Pagination = true;
        menu.SetTitle("Select:");
        Slot currentSlot = inventory.GetSlot(data.m_iLoadoutSlot);
        Definition chosenDef = currentSlot.m_Selected;
        if (chosenDef == NULL_DEFINITION)
            menu.AddItem("4294967295", "(Equipped) Default"); // 4294967295 is 0xFFFFFFFF
        else
            menu.AddItem("4294967295", "Default");
        
        // Show all definitions that fall into this category.
        for (Definition it = Definition.begin(); it != Definition.end(); ++it)
        {
            // Get the individual definition for the selected index.
            definition_t def;
            it.Get(def);

            // Check if it is appropriate for this slot and class.
            if ((data.m_iLoadoutSlot >= WEAPONS_LENGTH && def.GetSlot(data.m_eClass, 8))
                || def.GetSlot(data.m_eClass, LoadoutToTF2(data.m_iLoadoutSlot, data.m_eClass)))
            {
                // Is this a CWX weapon definition?
                if (strlen(def.m_szCWXUID) > 0 && g_LoadedCWX)
                {
                    if (!CWX_CanPlayerAccessItem(client, def.m_szCWXUID))
                        continue;
                }
                else
                {
                    // Skip if the item definition index is invalid.
                    if (def.m_iItemDef == TF_ITEMDEF_DEFAULT)
                        continue;
                }

                // Skip if this definition should not be displayed.
                if (!def.m_bShowInLoadout)
                    continue;

                // Check if medieval mode is on.
                if (GameRules_GetProp("m_bPlayingMedieval", 1))
                {
                    // If this definition is strictly not allowed in medieval mode, continue.
                    if (def.m_iAllowedInMedieval == 0)
                        continue;

                    // If this definition uses default behaviour, check its static attributes.
                    if (def.m_iAllowedInMedieval == -1 && (strlen(def.m_szCWXUID) > 0 || !AllowedOnMedievalByDefault(def.m_iItemDef, data.m_eClass)))
                        continue;
                }

                // Display in the loadout menu.
                Slot loadoutslot = inventory.GetSlot(data.m_iLoadoutSlot);
                char name[NAME_LENGTH + 11]; // "(Equipped) %s" where %s is NAME_LENGTH (64)
                char index[11]; // len("2147483648"): 10
                IntToString(it.m_iIndex, index, sizeof(index));
                if (loadoutslot.m_Selected == it)
                {
                    if (loadoutslot.m_bTemporary)
                        Format(name, sizeof(name), "(Temporarily Equipped) %s", def.m_szName);
                    else
                        Format(name, sizeof(name), "(Equipped) %s", def.m_szName);
                }
                else
                    strcopy(name, sizeof(name), def.m_szName);
                menu.AddItem(index, name);
            }
        }
    }

    // Display the menu.
    menu.Display(client, MENU_TIME_FOREVER);
}

//////////////////////////////////////////////////////////////////////////////
// FILES                                                                    //
//////////////////////////////////////////////////////////////////////////////

static void ExportKeyValues(const char[] buffer)
{
    KeyValues kv = new KeyValues("Loadout");
    kv.SetNum("#loaddefaults", g_bLoadDefaults);
    kv.SetNum("#whitelist", g_bWhitelist);
    kv.SetNum("#filterbotkiller", g_bFilterBotkiller);
    kv.SetNum("#filterfestive", g_bFilterFestive);
    kv.SetNum("#blockunlisted", g_bBlockUnlisted);
    kv.SetNum("#createmiscdefs", g_bCreateMiscDefs);
    for (Definition it = Definition.begin(); it != Definition.end(); ++it)
    {
        // Get definition - skip if m_bSave is false for optimisation.
        definition_t def;
        it.Get(def);
        if (!def.m_bSave)
            continue;

        // Write basic info.
        kv.JumpToKey(def.m_szName, true);
        kv.SetNum("#default", def.m_bDefault);
        kv.SetNum("#visible", def.m_bShowInLoadout);
        kv.SetNum("#medieval", def.m_iAllowedInMedieval);
        kv.SetString("#iscwx", def.m_szCWXUID);
        kv.SetString("#classname", def.m_szClassName);

        // Build class/slot information and write.
        char classinfo[320];
        for (TFClassType class = TFClass_Scout; class <= TFClass_Engineer; ++class)
        {
            bool writtenClass = false;
            for (int slot = 0; slot < MAX_SLOTS; ++slot)
            {
                if (def.GetSlot(class, slot))
                {
                    // Write class name.
                    if (!writtenClass)
                    {
                        StringMapSnapshot snapshot = g_Classes.Snapshot();
                        for (int i2 = 0, size = snapshot.Length; i2 < size; ++i2)
                        {
                            char className[NAME_LENGTH];
                            TFClassType classFound;
                            snapshot.GetKey(i2, className, sizeof(className));
                            g_Classes.GetValue(className, classFound);
                            if (classFound == class)
                            {
                                StrCat(classinfo, sizeof(classinfo), className);
                                break;
                            }
                        }
                        delete snapshot;
                        writtenClass = true;
                    }

                    // Write slot.
                    char slotbuffer[3];
                    Format(slotbuffer, sizeof(slotbuffer), " %i", slot);
                    StrCat(classinfo, sizeof(classinfo), slotbuffer);
                }
            }
            if (writtenClass)
                StrCat(classinfo, sizeof(classinfo), ";");
        }
        if (strlen(classinfo) == 0)
            classinfo = ";";
        kv.SetString("#classes", classinfo);

        // Return to the global scope.
        kv.Rewind();
    }
    PrintToServer("Exported to \"%s\": %s", buffer, (kv.ExportToFile(buffer) ? "true" : "false"));
    delete kv;
}

//////////////////////////////////////////////////////////////////////////////
// GENERAL COMMANDS                                                         //
//////////////////////////////////////////////////////////////////////////////

static Action cmd_loadout(int client, int args)
{
    // Check loadout perms.
    if (g_eLoadoutMenu == LOADOUT_OFF)
    {
        ReplyToCommand(client, "[Weapon Manager]: !loadout is off.");
        return Plugin_Handled;
    }
    else if (g_eLoadoutMenu == LOADOUT_ADMIN)
    {
        AdminId id = GetUserAdmin(client);
        if (!id.HasFlag(Admin_Generic))
        {
            ReplyToCommand(client, "[Weapon Manager]: !loadout is for server admins only.");
            return Plugin_Handled;
        }
    }
    else if (g_eLoadoutMenu == LOADOUT_SILENT)
        return Plugin_Handled;

    // Create the loadout menu.
    PlayerData data = PlayerData(client);
    data.m_iLoadoutSlot = -1;
    CreateLoadoutMenu(client);
    return Plugin_Handled;
}

// !gimme slot (name | item definition index) [persist]
static Action cmd_gimme(int client, int args)
{
    // Check command perms.
    if (g_eCommands == LOADOUT_OFF)
    {
        ReplyToCommand(client, "[Weapon Manager]: !gimme is off.");
        return Plugin_Handled;
    }
    else if (g_eCommands == LOADOUT_ADMIN)
    {
        AdminId id = GetUserAdmin(client);
        if (!id.HasFlag(Admin_Generic))
        {
            ReplyToCommand(client, "[Weapon Manager]: !gimme is for server admins only.");
            return Plugin_Handled;
        }
    }
    else if (g_eCommands == LOADOUT_SILENT)
        return Plugin_Handled;

    // Retrieve parameters.
    if (args < 2 || !(1 <= client <= MaxClients) || !IsClientInGame(client))
    {
        ReplyToCommand(client, "[Weapon Manager]: !gimme slot (name | item definition index) [persist]");
        return Plugin_Handled;
    }
    int slot = GetCmdArgInt(1);
    if (!(0 <= slot < WEAPONS_LENGTH))
    {
        ReplyToCommand(client, "[Weapon Manager]: Invalid slot!");
        return Plugin_Handled;
    }
    char name[NAME_LENGTH];
    GetCmdArg(2, name, sizeof(name));
    bool persist = false;
    if (args >= 3)
    {
        char buffer[64];
        GetCmdArg(3, buffer, sizeof(buffer));
        TrimString(buffer);
        if (strcmp(buffer, "persists", false) == 0 || strcmp(buffer, "persist", false) == 0)
            persist = true;
    }

    // Equip the weapon.
    if (GiveTo(client, slot, name, persist, client))
        ReplyToCommand(client, "[Weapon Manager]: Successfully equipped weapon!");
    else
        ReplyToCommand(client, "[Weapon Manager]: Could not give weapon.");
    return Plugin_Handled;
}

// !gimmenext class slot (name | item definition index)
static Action cmd_gimmenext(int client, int args)
{
    // Check command perms.
    if (g_eCommands == LOADOUT_OFF)
    {
        ReplyToCommand(client, "[Weapon Manager]: !gimmenext is off.");
        return Plugin_Handled;
    }
    else if (g_eCommands == LOADOUT_ADMIN)
    {
        AdminId id = GetUserAdmin(client);
        if (!id.HasFlag(Admin_Generic))
        {
            ReplyToCommand(client, "[Weapon Manager]: !gimmenext is for server admins only.");
            return Plugin_Handled;
        }
    }
    else if (g_eCommands == LOADOUT_SILENT)
        return Plugin_Handled;

    // Retrieve parameters.
    if (args != 3 || !(1 <= client <= MaxClients) || !IsClientInGame(client))
    {
        ReplyToCommand(client, "[Weapon Manager]: !gimmenext class slot (name | item definition index)");
        return Plugin_Handled;
    }
    int slot = GetCmdArgInt(2);
    if (!(0 <= slot < WEAPONS_LENGTH))
    {
        ReplyToCommand(client, "[Weapon Manager]: Invalid slot!");
        return Plugin_Handled;
    }
    char classbuffer[64], name[NAME_LENGTH];
    GetCmdArg(1, classbuffer, sizeof(classbuffer));
    GetCmdArg(3, name, sizeof(name));
    TrimString(classbuffer);
    StringToLower(classbuffer, classbuffer, sizeof(classbuffer));

    // Configure the class.
    TFClassType eClass = TFClass_Unknown;
    g_Classes.GetValue(classbuffer, eClass);
    if (eClass == TFClass_Unknown)
    {
        ReplyToCommand(client, "[Weapon Manager]: Invalid class \"%s\"!", classbuffer);
        return Plugin_Handled;
    }

    // Toggle the definition.
    if (GiveToNext(client, eClass, slot, name, client))
        ReplyToCommand(client, "[Weapon Manager]: Make sure to hit resupply.");
    else
        ReplyToCommand(client, "[Weapon Manager]: Could not toggle weapon.");
    return Plugin_Handled;
}

// !unequip class slot
static Action cmd_unequip(int client, int args)
{
    // Check command perms.
    if (g_eCommands == LOADOUT_OFF)
    {
        ReplyToCommand(client, "[Weapon Manager]: !unequip is off.");
        return Plugin_Handled;
    }
    else if (g_eCommands == LOADOUT_ADMIN)
    {
        AdminId id = GetUserAdmin(client);
        if (!id.HasFlag(Admin_Generic))
        {
            ReplyToCommand(client, "[Weapon Manager]: !unequip is for server admins only.");
            return Plugin_Handled;
        }
    }
    else if (g_eCommands == LOADOUT_SILENT)
        return Plugin_Handled;

    // Retrieve parameters.
    if (args != 2 || !(1 <= client <= MaxClients) || !IsClientInGame(client))
    {
        ReplyToCommand(client, "[Weapon Manager]: !unequip class slot");
        return Plugin_Handled;
    }
    char classbuffer[64];
    GetCmdArg(1, classbuffer, sizeof(classbuffer));
    TrimString(classbuffer);
    StringToLower(classbuffer, classbuffer, sizeof(classbuffer));
    int slot = GetCmdArgInt(2);
    if (!(0 <= slot < WEAPONS_LENGTH))
    {
        ReplyToCommand(client, "[Weapon Manager]: Invalid slot!");
        return Plugin_Handled;
    }

    // Configure the class.
    TFClassType eClass = TFClass_Unknown;
    g_Classes.GetValue(classbuffer, eClass);
    if (eClass == TFClass_Unknown)
    {
        ReplyToCommand(client, "[Weapon Manager]: Invalid class \"%s\"!", classbuffer);
        return Plugin_Handled;
    }

    // Untoggle the definition.
    if (RemovePersist(client, eClass, slot))
        ReplyToCommand(client, "[Weapon Manager]: Make sure to hit resupply.");
    else
        ReplyToCommand(client, "[Weapon Manager]: There was no definition to untoggle.");
    return Plugin_Handled;
}

//////////////////////////////////////////////////////////////////////////////
// ADMIN COMMANDS                                                           //
//////////////////////////////////////////////////////////////////////////////

// Creates a file (if it doesn't exist beforehand) and writes all definitions to it. 
// If no name is provided, it will write to autosave.cfg
static Action weapon_write(int client, int args)
{
    // Check for a passed argument.
    char arg[PLATFORM_MAX_PATH];
    char buffer[PLATFORM_MAX_PATH];
    if (args == 0)
        strcopy(buffer, sizeof(buffer), AUTOSAVE_PATH);
    else
    {
        GetCmdArg(1, arg, sizeof(arg));
        TrimString(arg);
        Format(buffer, sizeof(buffer), "addons/sourcemod/configs/weapon_manager/%s.cfg", arg);
    }

    // Open a new file.
    if (!DirExists("addons/sourcemod/configs/weapon_manager/", true))
        CreateDirectory("addons/sourcemod/configs/weapon_manager/", .use_valve_fs = true);

    File file = OpenFile(buffer, "w", true);
    if (!file)
    {
        ReplyToCommand(client, "[Weapon Manager]: Unable to create file \"%s.cfg\"", arg);
        return Plugin_Continue;
    }
    delete file;

    // Create a KeyValues pair and export it to the file.
    ExportKeyValues(buffer);

    // Return to command.
    ReplyToCommand(client, "[Weapon Manager]: Finished writing to \"%s\"", ((strlen(arg) > 0) ? arg : "autosave"));
    return Plugin_Continue;
}

// Load definitions from an existing config.
static Action weapon_loadconfig(int client, int args)
{
    // Check for a passed argument.
    if (args == 0)
    {
        ReplyToCommand(client, "[Weapon Manager]: weapon_loadconfig configname");
        return Plugin_Continue;
    }
    char arg[PLATFORM_MAX_PATH];
    char buffer[PLATFORM_MAX_PATH];
    GetCmdArg(1, arg, sizeof(arg));
    TrimString(arg);
    Format(buffer, sizeof(buffer), "addons/sourcemod/configs/weapon_manager/%s.cfg", arg);

    // Check if it exists.
    if (!FileExists(buffer))
    {
        ReplyToCommand(client, "[Weapon Manager]: File \"%s.cfg\" does not exist", arg);
        return Plugin_Continue;
    }

    // Load all definitions from the file.
    ParseDefinitions(buffer);
    strcopy(g_szCurrentPath, sizeof(g_szCurrentPath), buffer);

    // Return to command.
    ReplyToCommand(client, "[Weapon Manager]: Loaded config \"%s.cfg\"", arg);
    return Plugin_Continue;
}

// List all the names of the current definitions.
static Action weapon_listdefinitions(int client, int args)
{
    // Check if there are any current definitions.
    if (g_DefinitionsSnapshot.Length == 0)
    {
        ReplyToCommand(client, "[Weapon Manager]: No definitions currently.");
        return Plugin_Continue;
    }

    // Retrieve any additional parametres if desired.
    char classbuffer[64];
    GetCmdArg(1, classbuffer, sizeof(classbuffer));
    TrimString(classbuffer);
    StringToLower(classbuffer, classbuffer, sizeof(classbuffer));
    int slot = -1;
    if (args >= 2)
        slot = GetCmdArgInt(2);

    // Configure the class.
    TFClassType eClass = TFClass_Unknown;
    g_Classes.GetValue(classbuffer, eClass);

    // Go through each definition and list its details.
    for (Definition it = Definition.begin(); it != Definition.end(); ++it)
    {
        // Write to g_DefinitionsByIndex.
        definition_t def;
        it.Get(def);

        // Skip if it is not toggled to be saved.
        if (!def.m_bSave)
            continue;

        // Skip if it is not toggled for this class.
        if (eClass != TFClass_Unknown && !def.AllowedOnClass(eClass))
            continue;

        // Skip if it is not toggled for this slot.
        if (slot != -1 && eClass != TFClass_Unknown && !def.GetSlot(eClass, slot))
            continue;

        ReplyToCommand(client, "[Weapon Manager]: Definition \"%s\" (%s)", def.m_szName, ((def.m_iItemDef != TF_ITEMDEF_DEFAULT) ? "Native Weapon" : ((strlen(def.m_szCWXUID) > 0) ? "CWX Weapon" : "Custom tag")));
    }
    return Plugin_Continue;
}

// Add a new definition (native weapon, cwx weapon or custom tag).
// If specified, it can inherit from another definition.
static Action weapon_add(int client, int args)
{
    // Retrieve the name (and definition to inherit from) provided.
    if (args < 1)
    {
        ReplyToCommand(client, "[Weapon Manager]: weapon_add (name | item definition index) [inherits]");
        return Plugin_Continue;
    }
    char arg[64], inherits_string[64];
    GetCmdArg(1, arg, sizeof(arg));
    GetCmdArg(2, inherits_string, sizeof(inherits_string));
    TrimString(arg);
    TrimString(inherits_string);

    // Attempt to retrieve the item definition index from the section name.
    int itemdef = CalculateItemDefFromSectionName(arg);

    // Check if the definition already exists.
    definition_t exists;
    if (FindDefinition(exists, arg, itemdef) && exists.m_bSave)
    {
        ReplyToCommand(client, "[Weapon Manager]: Definition %s already exists!", arg);
        return Plugin_Continue;
    }

    // Create a new definition and write basic information.
    definition_t def;
    CreateDefinition(def, arg, itemdef);
    def.m_bAutomaticallyConfigured = false;
    def.m_bSave = true;
    def.m_szCWXUID = "";
    def.m_bShowInLoadout = true;
    def.m_iAllowedInMedieval = -1;
    def.m_bDefault = false;
    if (def.m_iItemDef != TF_ITEMDEF_DEFAULT)
        TF2Econ_GetItemClassName(def.m_iItemDef, def.m_szClassName, sizeof(def.m_szClassName));

    // Write class/slot information.
    for (TFClassType class = TFClass_Scout; class <= TFClass_Engineer; ++class)
    {
        // Get the slot used for this weapon.
        // ALWAYS set it to true if this is a stock weapon.
        // Otherwise, only set it to true if g_bWhitelist == false.
        int slot = TF2Econ_GetItemLoadoutSlot(itemdef, class);
        if (slot == -1)
            continue;
        def.SetSlot(class, slot, true);
    }

    // Inherit basic information if we found an inherited definition.
    definition_t inherits_def;
    if (FindDefinition(inherits_def, inherits_string))
    {
        strcopy(def.m_szClassName, sizeof(def.m_szClassName), inherits_def.m_szClassName);
        strcopy(def.m_szCWXUID, sizeof(def.m_szCWXUID), inherits_def.m_szCWXUID);
        def.m_ClassInformation = inherits_def.m_ClassInformation;
        def.m_bDefault = inherits_def.m_bDefault;
    }

    // Reply to command, export the new definition and re-parse all definitions.
    def.PushToArray();
    g_DefinitionsSnapshot = g_Definitions.Snapshot();
    ExportKeyValues(g_szCurrentPath);
    ParseDefinitions(g_szCurrentPath);
    ReplyToCommand(client, "[Weapon Manager]: Successfully added new definition \"%s\"", def.m_szName);
    return Plugin_Continue;
}

// Remove a definition (native weapon, cwx weapon or custom tag).
static Action weapon_remove(int client, int args)
{
    // Retrieve the name provided.
    if (args < 1)
    {
        ReplyToCommand(client, "[Weapon Manager]: weapon_remove (name | item definition index)");
        return Plugin_Continue;
    }
    char arg[64];
    GetCmdArg(1, arg, sizeof(arg));
    TrimString(arg);

     // Attempt to retrieve the item definition index from the section name.
    int itemdef = CalculateItemDefFromSectionName(arg);

    // Check that the definition already exists.
    definition_t exists;
    if (!FindDefinition(exists, arg, itemdef) || !exists.m_bSave)
    {
        ReplyToCommand(client, "[Weapon Manager]: Definition %s does not exist!", arg);
        return Plugin_Continue;
    }

    // Delete the definition.
    exists.Delete();
    g_DefinitionsSnapshot = g_Definitions.Snapshot();
    ExportKeyValues(g_szCurrentPath);
    ParseDefinitions(g_szCurrentPath);
    ReplyToCommand(client, "[Weapon Manager]: Successfully deleted definition %s", arg);
    return Plugin_Continue;
}

// Modify a definition's property.
static Action weapon_modify(int client, int args)
{
    // Retrieve the name, property and value
    if (args != 3)
    {
        ReplyToCommand(client, "[Weapon Manager]: weapon_modify (name | item definition index) property value");
        return Plugin_Continue;
    }
    char name[64], prop[64], value[64];
    GetCmdArg(1, name, sizeof(name));
    GetCmdArg(2, prop, sizeof(prop));
    GetCmdArg(3, value, sizeof(value));
    TrimString(name);
    TrimString(prop);
    TrimString(value);

    // Convert the value to an int if it is a boolean.
    if (strcmp(value, "true", false) == 0)
        value = "1";
    else if (strcmp(value, "false", false) == 0)
        value = "0";

     // Attempt to retrieve the item definition index from the section name.
    int itemdef = CalculateItemDefFromSectionName(name);

    // Check that the definition already exists.
    definition_t def;
    if (!FindDefinition(def, name, itemdef) || !def.m_bSave)
    {
        ReplyToCommand(client, "[Weapon Manager]: Definition %s does not exist!", name);
        return Plugin_Continue;
    }

    // Modify the property.
    if (strcmp(prop, "classname", false) == 0)
        strcopy(def.m_szClassName, sizeof(def.m_szClassName), value);
    else if (strcmp(prop, "iscwx", false) == 0)
    {
        strcopy(def.m_szCWXUID, sizeof(def.m_szCWXUID), value);
        if (strlen(def.m_szCWXUID) == 0)
        {
            if (def.m_iItemDef != TF_ITEMDEF_DEFAULT)
                ReplyToCommand(client, "[Weapon Manager]: Definition \"%s\" is now set to a native weapon.", def.m_szName);
            else
                ReplyToCommand(client, "[Weapon Manager]: Definition \"%s\" is now set to a custom tag.", def.m_szName);
        }
        else
            ReplyToCommand(client, "[Weapon Manager]: Definition \"%s\" is now set to a CWX weapon.", def.m_szName);
    }
    else if (strcmp(prop, "default", false) == 0)
        def.m_bDefault = view_as<bool>(StringToInt(value));
    else if (strcmp(prop, "visible", false) == 0)
        def.m_bDefault = view_as<bool>(StringToInt(value));
    else if (strcmp(prop, "medieval", false) == 0)
        def.m_iAllowedInMedieval = StringToInt(value);
    else if (strcmp(prop, "classes", false) == 0)
    {
        ReplyToCommand(client, "[Weapon Manager]: Please use the \"weapon_toggleslot\" and \"weapon_disable\" commands!");
        return Plugin_Continue;
    }
    else
    {
        ReplyToCommand(client, "[Weapon Manager]: Property \"%s\" does not exist!", prop);
        return Plugin_Continue;
    }

    // Reply to command, re-export the definition and re-parse all definitions.
    def.m_bSave = true;
    def.Delete();
    def.PushToArray();
    g_DefinitionsSnapshot = g_Definitions.Snapshot();
    ExportKeyValues(g_szCurrentPath);
    ParseDefinitions(g_szCurrentPath);
    ReplyToCommand(client, "[Weapon Manager]: Successfully modified property \"%s\" for definition \"%s\"", prop, def.m_szName);
    return Plugin_Continue;
}

// Reparse all definitions.
static Action weapon_refresh(int client, int args)
{
    ExportKeyValues(g_szCurrentPath);
    ParseDefinitions(g_szCurrentPath);
    ReplyToCommand(client, "[Attribute Manager]: Refreshed all definitions");
    return Plugin_Continue;
}

// Toggle a definition's slot.
static Action weapon_toggleslot(int client, int args)
{
    // Retrieve the name, class, slot and value
    if (args != 4)
    {
        ReplyToCommand(client, "[Weapon Manager]: weapon_toggleslot (name | item definition index) class slot value");
        return Plugin_Continue;
    }
    char name[64], classbuffer[64], slot[64], value[64];
    GetCmdArg(1, name, sizeof(name));
    GetCmdArg(2, classbuffer, sizeof(classbuffer));
    GetCmdArg(3, slot, sizeof(slot));
    GetCmdArg(4, value, sizeof(value));
    TrimString(name);
    TrimString(classbuffer);
    TrimString(slot);
    TrimString(value);

    // Convert the value to an int if it is a boolean.
    if (strcmp(value, "true", false) == 0)
        value = "1";
    else if (strcmp(value, "false", false) == 0)
        value = "0";

    // Attempt to retrieve the item definition index from the section name.
    int itemdef = CalculateItemDefFromSectionName(name);
    
    // Configure the class.
    TFClassType eClass = TFClass_Unknown;
    g_Classes.GetValue(classbuffer, eClass);
    if (eClass == TFClass_Unknown)
    {
        ReplyToCommand(client, "[Weapon Manager]: Could not find class \"%s\"!", classbuffer);
        return Plugin_Continue;
    }

    // Configure the slot.
    int slotindex = StringToInt(slot);
    if ((slotindex == 0 && !EqualsZero(slot) || !(0 <= slotindex < WEAPONS_LENGTH)))
    {
        ReplyToCommand(client, "[Weapon Manager]: Invalid slot \"%s\".", slot);
        return Plugin_Continue;
    }

    // Check that the definition already exists.
    definition_t def;
    if (!FindDefinition(def, name, itemdef) || !def.m_bSave)
    {
        ReplyToCommand(client, "[Weapon Manager]: Definition %s does not exist!", name);
        return Plugin_Continue;
    }

    // Toggle the definition's slot.
    def.SetSlot(eClass, LoadoutToTF2(slotindex, eClass), view_as<bool>(StringToInt(value)));
    def.Delete();
    def.PushToArray();
    g_DefinitionsSnapshot = g_Definitions.Snapshot();
    ExportKeyValues(g_szCurrentPath);
    ParseDefinitions(g_szCurrentPath);
    ReplyToCommand(client, "[Weapon Manager]: Successfully toggled slot \"%i\" for class \"%s\" for definition \"%s\"!", slotindex, classbuffer, name);
    return Plugin_Continue;
}

// Disable a definition for a specific class.
static Action weapon_disable(int client, int args)
{
    // Retrieve the name,
    if (args != 2)
    {
        ReplyToCommand(client, "[Weapon Manager]: weapon_disable (name | item definition index) class");
        return Plugin_Continue;
    }
    char name[64], classbuffer[64];
    GetCmdArg(1, name, sizeof(name));
    GetCmdArg(2, classbuffer, sizeof(classbuffer));
    TrimString(name);
    TrimString(classbuffer);

    // Attempt to retrieve the item definition index from the section name.
    int itemdef = CalculateItemDefFromSectionName(name);

    // Check that the definition already exists.
    definition_t def;
    if (!FindDefinition(def, name, itemdef) || !def.m_bSave)
    {
        ReplyToCommand(client, "[Weapon Manager]: Definition %s does not exist!", name);
        return Plugin_Continue;
    }
    
    // Configure the class.
    TFClassType eClass = TFClass_Unknown;
    g_Classes.GetValue(classbuffer, eClass);
    if (eClass == TFClass_Unknown)
    {
        ReplyToCommand(client, "[Weapon Manager]: Could not find class \"%s\"!", classbuffer);
        return Plugin_Continue;
    }

    // Block the definition for this class.
    for (int i = 0; i < WEAPONS_LENGTH; ++i)
        def.SetSlot(eClass, LoadoutToTF2(i, eClass), false);
    def.Delete();
    def.PushToArray();
    g_DefinitionsSnapshot = g_Definitions.Snapshot();
    ExportKeyValues(g_szCurrentPath);
    ParseDefinitions(g_szCurrentPath);
    ReplyToCommand(client, "[Weapon Manager]: Successfully disabled the definition \"%s\" for class \"%s\"!", name, classbuffer);
    return Plugin_Continue;
}

// List the properties of a definition.
static Action weapon_listdefinition(int client, int args)
{
    // Retrieve the name provided.
    if (args < 1)
    {
        ReplyToCommand(client, "[Attribute Manager]: weapon_listdefinition (name | item definition index)");
        return Plugin_Continue;
    }
    char arg[64];
    GetCmdArg(1, arg, sizeof(arg));
    TrimString(arg);

    // Attempt to retrieve the item definition index from the section name.
    int itemdef = CalculateItemDefFromSectionName(arg);

    // Check that the definition already exists.
    definition_t def;
    if (!FindDefinition(def, arg, itemdef) || !def.m_bSave)
    {
        ReplyToCommand(client, "[Weapon Manager]: Definition %s does not exist!", arg);
        return Plugin_Continue;
    }

    // Print all the properties for the definition
    ReplyToCommand(client, "[Weapon Manager]: %s:", def.m_szName);
    if (def.m_iItemDef != TF_ITEMDEF_DEFAULT)
        ReplyToCommand(client, "[Weapon Manager]: (Item definition index) %i", def.m_iItemDef);
    else if (strlen(def.m_szCWXUID) > 0)
        ReplyToCommand(client, "[Weapon Manager]: (Status) CWX Weapon");
    else
        ReplyToCommand(client, "[Weapon Manager]: (Status) Custom Tag");
    ReplyToCommand(client, "(Property) #classname: %s", def.m_szClassName);
    ReplyToCommand(client, "(Property) #iscwx: %s", def.m_szCWXUID);
    ReplyToCommand(client, "(Property) #default: %i", def.m_bDefault);
    ReplyToCommand(client, "(Property) #visible: %i", def.m_bShowInLoadout);
    ReplyToCommand(client, "(Property) #medieval: %i", def.m_iAllowedInMedieval);

    // Print the slots this definition is toggled on for each class (uses loadout slot numbers).
    for (TFClassType class = TFClass_Scout; class <= TFClass_Engineer; ++class)
    {
        // Resolve the class name.
        char buffer[NAME_LENGTH + 64]; // (%s) Slots toggled: %i %i %i %i %i
        StringMapSnapshot snapshot = g_Classes.Snapshot();
        for (int i = 0, size = snapshot.Length; i < size; ++i)
        {
            char className[NAME_LENGTH];
            TFClassType classFound;
            snapshot.GetKey(i, className, sizeof(className));
            g_Classes.GetValue(className, classFound);
            if (classFound == class)
            {
                Format(buffer, sizeof(buffer), "(%s) Slots toggled:", className);
                break;
            }
        }
        delete snapshot;

        // Check the slots toggled.
        bool found = false;
        for (int slot = 0; slot < ((class == TFClass_Engineer || class == TFClass_Spy) ? WEAPONS_LENGTH : 3); ++slot)
        {
            char old[sizeof(buffer)];
            strcopy(old, sizeof(old), buffer);
            if (def.GetSlot(class, LoadoutToTF2(slot, class)))
            {
                Format(buffer, sizeof(buffer), "%s %i", old, slot);
                found = true;
            }
        }
        if (found)
            ReplyToCommand(client, buffer);
    }

    // Return to command.
    return Plugin_Continue;
}

// Give a weapon immediately to a player. You can choose whether it should persist.
static Action weapon_giveto(int client, int args)
{
    // Retrieve parameters.
    if (args < 3)
    {
        ReplyToCommand(client, "[Weapon Manager]: weapon_giveto player slot (name | item definition index) [persist]");
        return Plugin_Handled;
    }
    int slot = GetCmdArgInt(2);
    if (!(0 <= slot < WEAPONS_LENGTH))
    {
        ReplyToCommand(client, "[Weapon Manager]: Invalid slot!");
        return Plugin_Handled;
    }
    char playername[64], name[NAME_LENGTH];
    GetCmdArg(1, playername, sizeof(playername));
    GetCmdArg(3, name, sizeof(name));
    bool persist = false;
    if (args >= 4)
    {
        char buffer[64];
        GetCmdArg(4, buffer, sizeof(buffer));
        TrimString(buffer);
        if (strcmp(buffer, "persists", false) == 0 || strcmp(buffer, "persist", false) == 0)
            persist = true;
    }

    // Retrieve the player to assign this weapon to.
    int target = FindTarget(client, playername);
    if (target == -1)
    {
        ReplyToCommand(client, "[Weapon Manager]: Could not find target \"%s\"!", playername);
        return Plugin_Handled;
    }

    // Equip the weapon.
    if (GiveTo(target, slot, name, persist, client))
    {
        PrintToChat(target, "[Weapon Manager]: You have been given a weapon by \"%N\"!", client);
        ReplyToCommand(client, "[Weapon Manager]: Successfully given weapon to \"%N\"!", target);
    }
    else
        ReplyToCommand(client, "[Weapon Manager]: Could not give weapon.");
    return Plugin_Handled;
}

// Assign a weapon to a player, which will be equipped on resupply.
static Action weapon_givetonext(int client, int args)
{
    // Retrieve parameters.
    if (args < 4)
    {
        ReplyToCommand(client, "[Weapon Manager]: weapon_givetonext player class slot (name | item definition index)");
        return Plugin_Handled;
    }
    int slot = GetCmdArgInt(3);
    if (!(0 <= slot < WEAPONS_LENGTH))
    {
        ReplyToCommand(client, "[Weapon Manager]: Invalid slot!");
        return Plugin_Handled;
    }
    char playername[64], classbuffer[64], name[NAME_LENGTH];
    GetCmdArg(1, playername, sizeof(playername));
    GetCmdArg(2, classbuffer, sizeof(classbuffer));
    GetCmdArg(4, name, sizeof(name));

    // Retrieve the player to assign this weapon to.
    int target = FindTarget(client, playername);
    if (target == -1)
    {
        ReplyToCommand(client, "[Weapon Manager]: Could not find target \"%s\"!", playername);
        return Plugin_Handled;
    }

    // Configure the class.
    TFClassType eClass = TFClass_Unknown;
    g_Classes.GetValue(classbuffer, eClass);
    if (eClass == TFClass_Unknown)
    {
        ReplyToCommand(client, "[Weapon Manager]: Invalid class \"%s\"!", classbuffer);
        return Plugin_Handled;
    }

    // Toggle the definition.
    if (GiveToNext(target, eClass, slot, name, client))
    {
        PrintToChat(target, "[Weapon Manager]: You have been assigned a weapon by \"%N\". Make sure to hit resupply.", client);
        ReplyToCommand(client, "[Weapon Manager]: Successfully toggled weapon on player \"%N\"!", target);
    }
    else
        ReplyToCommand(client, "[Weapon Manager]: Could not toggle weapon.");
    return Plugin_Handled;
}

// Unequip a weapon from a player, which will take place on resupply.
static Action weapon_unequipfrom(int client, int args)
{
    // Retrieve parameters.
    if (args < 3)
    {
        ReplyToCommand(client, "[Weapon Manager]: weapon_unequipfrom player class slot");
        return Plugin_Handled;
    }
    char playername[64], classbuffer[64];
    GetCmdArg(1, playername, sizeof(playername));
    GetCmdArg(2, classbuffer, sizeof(classbuffer));
    int slot = GetCmdArgInt(3);
    if (!(0 <= slot < WEAPONS_LENGTH))
    {
        ReplyToCommand(client, "[Weapon Manager]: Invalid slot!");
        return Plugin_Handled;
    }

    // Retrieve the player to assign this weapon to.
    int target = FindTarget(client, playername);
    if (target == -1)
    {
        ReplyToCommand(client, "[Weapon Manager]: Could not find target \"%s\"!", playername);
        return Plugin_Handled;
    }

    // Configure the class.
    TFClassType eClass = TFClass_Unknown;
    g_Classes.GetValue(classbuffer, eClass);
    if (eClass == TFClass_Unknown)
    {
        ReplyToCommand(client, "[Weapon Manager]: Invalid class \"%s\"!", classbuffer);
        return Plugin_Handled;
    }

    // Toggle the definition.
    if (RemovePersist(target, eClass, slot))
    {
        PrintToChat(target, "[Weapon Manager]: A weapon has been removed from you by \"%N\". Make sure to hit resupply.", client);
        ReplyToCommand(client, "[Weapon Manager]: Successfully removed weapon from player \"%N\"!", target);
    }
    else
        ReplyToCommand(client, "[Weapon Manager]: There was no weapon to remove.");
    return Plugin_Handled;
}

//////////////////////////////////////////////////////////////////////////////
// NATIVES                                                                  //
//////////////////////////////////////////////////////////////////////////////

public any Native_WeaponManager_IsPluginReady(Handle plugin, int numParams)
{
    if (g_AllLoaded)
        return true;
    return false;
}

// Returns an ArrayList of definitions.
public any Native_WeaponManager_GetDefinitions(Handle plugin, int numParams)
{
    if (g_Definitions == null)
        return INVALID_HANDLE;
    return g_Definitions.Clone();
}

// Updates g_Definitions on the plugin's end.
public any Native_WeaponManager_SetDefinitions(Handle plugin, int numParams)
{
    // The following code is copied from the beginning of ParseDefinitions().
    
    // Clear loadouts.
    for (int client = 1; client <= MaxClients; ++client)
    {
        if (IsClientInGame(client))
        {
            for (TFClassType class = TFClass_Unknown; class <= TFClass_Engineer; ++class)
                PlayerData(client).GetInventory(class).Clear();
        }
    }

    // Clear default definitions list.
    for (int x = 0; x < sizeof(g_DefaultDefinitionBuffers); ++x)
    {
        for (int y = 0; y < sizeof(g_DefaultDefinitionBuffers[]); ++y)
        {
            g_DefaultDefinitionBuffers[x][y] = "";
            g_DefaultDefinitions[x][y] = NULL_DEFINITION;
        }
    }

    // Disable the by-index list.
    for (int i = 0; i < sizeof(g_DefinitionsByIndex); ++i)
        g_DefinitionsByIndex[i].m_bToggled = false;

    // Clear existing list.
    g_Definitions.Clear();
    if (g_DefinitionsSnapshot)
        delete g_DefinitionsSnapshot;

    // Update the g_Definitions StringMap.
    StringMap list = GetNativeCell(1);
    g_Definitions = list.Clone();

    // Make a snapshot of g_Definitions. (Copied from the closure of ParseDefinitions().)
    g_DefinitionsSnapshot = g_Definitions.Snapshot();
    for (Definition it = Definition.begin(); it != Definition.end(); ++it)
    {
        // Write to g_DefinitionsByIndex.
        definition_t def;
        it.Get(def);
        if (def.m_iItemDef != TF_ITEMDEF_DEFAULT)
        {
            g_DefinitionsByIndex[def.m_iItemDef].m_bToggled = true;
            g_DefinitionsByIndex[def.m_iItemDef].m_Object = it;
        }

        // Write to g_DefaultDefinitions. God this code is fucking stupid.
        if (def.m_bActualDefault)
        {
            for (TFClassType class = TFClass_Scout; class <= TFClass_Engineer; ++class)
            {
                for (int slot = 0; slot < MAX_SLOTS; ++slot)
                {
                    if (IsDefinitionAllowed(def, class, slot))
                        g_DefaultDefinitions[class][slot] = it;
                }
            }
        }
    }

    // Return.
    return 0;
}

// Writes all definitions to a config file.
public any Native_WeaponManager_Write(Handle plugin, int numParams)
{
    // Check for a passed argument.
    char arg[PLATFORM_MAX_PATH];
    char buffer[PLATFORM_MAX_PATH];
    
    int bytes;
    GetNativeString(1, arg, sizeof(arg), bytes);
    if (bytes == 0)
        strcopy(buffer, sizeof(buffer), AUTOSAVE_PATH);
    else
    {
        TrimString(arg);
        Format(buffer, sizeof(buffer), "addons/sourcemod/configs/weapon_manager/%s.cfg", arg);
    }

    // Open a new file.
    if (!DirExists("addons/sourcemod/configs/weapon_manager/", true))
        CreateDirectory("addons/sourcemod/configs/weapon_manager/", .use_valve_fs = true);

    File file = OpenFile(buffer, "w", true);
    if (!file)
        return false;
    delete file;

    // Create a KeyValues pair and export it to the file.
    ExportKeyValues(buffer);

    // Return to command.
    return true;
}

// Load definitions from a config file.
public any Native_WeaponManager_Load(Handle plugin, int numParams)
{
    // Check for a passed argument.
    char arg[PLATFORM_MAX_PATH];
    char buffer[PLATFORM_MAX_PATH];
    GetNativeString(1, arg, sizeof(arg));
    TrimString(arg);
    Format(buffer, sizeof(buffer), "addons/sourcemod/configs/weapon_manager/%s.cfg", arg);

    // Check if it exists.
    if (!FileExists(buffer))
        return false;
    
    // Load all definitions from the file.
    ParseDefinitions(buffer);
    strcopy(g_szCurrentPath, sizeof(g_szCurrentPath), buffer);

    // Return to command.
    return true;
}

// Re-parses definitions from the currently loaded config file.
public any Native_WeaponManager_Refresh(Handle plugin, int numParams)
{
    ExportKeyValues(g_szCurrentPath);
    ParseDefinitions(g_szCurrentPath);
    return 0;
}

// Returns the path of the current config file loaded.
public any Native_WeaponManager_GetLoadedConfig(Handle plugin, int numParams)
{
    int maxlength = GetNativeCell(2);
    int bytes = 0;
    SetNativeString(1, g_szCurrentPath, maxlength, true, bytes);
    return bytes;
}

// Modifies the value of a key-value in the configs/weapon_manager.cfg file.
public any Native_WeaponManager_DispatchGlobalKeyValue(Handle plugin, int numParams)
{
    // Retrieve parameters.
    char key[PLATFORM_MAX_PATH];
    char value[PLATFORM_MAX_PATH];
    GetNativeString(1, key, sizeof(key));
    GetNativeString(2, value, sizeof(value));

    // Open configs/weapon_manager.cfg and insert the new key/value pair.
    KeyValues kv = new KeyValues("Settings");
    if (!kv.ImportFromFile(GLOBALS_PATH))
        return false;
    kv.SetString(key, value);
    if (!kv.ExportToFile(GLOBALS_PATH))
        return false;
    delete kv;

    // Return to command.
    ParseDefinitions(g_szCurrentPath);
    return true;
}

// Retrieves the value of a key-value in the configs/weapon_manager.cfg file
public any Native_WeaponManager_GetGlobalKeyValue(Handle plugin, int numParams)
{
    // Retrieve parameters.
    char key[PLATFORM_MAX_PATH];
    char value[PLATFORM_MAX_PATH];
    GetNativeString(1, key, sizeof(key));
    
    // Open configs/weapon_manager.cfg and retrieve the desired key/value pair.
    KeyValues kv = new KeyValues("Settings");
    if (!kv.ImportFromFile(GLOBALS_PATH))
        return false;
    kv.GetString(key, value, sizeof(value));
    delete kv;
    
    // Return to command.
    SetNativeString(2, value, GetNativeCell(3));
    return true;
}

// Modifies the value of a key-value in the loaded definitions config file.
public any Native_WeaponManager_DispatchConfigKeyValue(Handle plugin, int numParams)
{
    // Retrieve parameters.
    char key[PLATFORM_MAX_PATH];
    char value[PLATFORM_MAX_PATH];
    GetNativeString(1, key, sizeof(key));
    GetNativeString(2, value, sizeof(value));

    // Open configs/weapon_manager.cfg and insert the new key/value pair.
    KeyValues kv = new KeyValues("Loadout");
    if (!kv.ImportFromFile(g_szCurrentPath))
        return false;
    kv.SetString(key, value);
    if (!kv.ExportToFile(g_szCurrentPath))
        return false;
    delete kv;

    // Return to command.
    ParseDefinitions(g_szCurrentPath);
    return true;
}

// Retrieves the value of a key-value in the loaded definitions config file.
public any Native_WeaponManager_GetConfigKeyValue(Handle plugin, int numParams)
{
    // Retrieve parameters.
    char key[PLATFORM_MAX_PATH];
    char value[PLATFORM_MAX_PATH];
    GetNativeString(1, key, sizeof(key));
    
    // Open configs/weapon_manager.cfg and retrieve the desired key/value pair.
    KeyValues kv = new KeyValues("Loadout");
    if (!kv.ImportFromFile(g_szCurrentPath))
        return false;
    kv.GetString(key, value, sizeof(value));
    delete kv;
    
    // Return to command.
    SetNativeString(2, value, GetNativeCell(3));
    return true;
}

// Find a definition_t by name.
public any Native_WeaponManager_FindDefinition(Handle plugin, int numParams)
{
    // Retrieve parameters.
    char name[NAME_LENGTH];
    GetNativeString(1, name, sizeof(name));

    // Call FindDefinition() and return to command.
    definition_t def;
    bool result = FindDefinition(def, name);
    SetNativeArray(2, def, sizeof(def));
    return result;
}

// Find a definition_t by item definition index.
public any Native_WeaponManager_FindDefinitionByItemDef(Handle plugin, int numParams)
{
    // Retrieve parameters.
    int itemdef = GetNativeCell(1);

    // Attempt to find an appropriate definition and return to command.
    if (g_DefinitionsByIndex[itemdef].m_bToggled && g_DefinitionsByIndex[itemdef].m_Object != NULL_DEFINITION)
    {
        definition_t def;
        view_as<Definition>(g_DefinitionsByIndex[itemdef].m_Object).Get(def);
        SetNativeArray(2, def, sizeof(def));
        return true;
    }
    return false;
}

// Force a player to immediately equip a new weapon according to a definition
// (by name), which will not persist after resuply (unless specified). 
// You can choose to persist later otherwise by using 
// WeaponManager_ForcePersistDefinition() with the matching definition.
//
// Use the slot corresponding to what key you typically use to equip this weapon
// (starting from 0 for primary).
//
// Note to self: if cosmetic code is implemented, use 8 for cosmetics as slot
public any Native_WeaponManager_EquipDefinition(Handle plugin, int numParams)
{
    // Retrieve parameters.
    int client = GetNativeCell(1);
    if (!(1 <= client <= MaxClients) || !IsClientInGame(client))
        return false;
    int slot = GetNativeCell(2);
    if (!(0 <= slot < WEAPONS_LENGTH))
        return false;
    char name[NAME_LENGTH];
    GetNativeString(3, name, sizeof(name));
    bool persist = GetNativeCell(4);

    // Equip the weapon.
    return GiveTo(client, slot, name, persist);
}

// Force a player to equip a new weapon according to a definition (by name) 
// after resupply. This weapon will persist until unequipped through the
// loadout menu, or through natives.
//
// Use the slot corresponding to what key you typically use to equip this weapon
// (starting from 0 for primary).
//
// Note to self: if cosmetic code is implemented, use 8 for cosmetics as slot
public any Native_WeaponManager_ForcePersistDefinition(Handle plugin, int numParams)
{
    // Retrieve parameters.
    int client = GetNativeCell(1);
    if (!(1 <= client <= MaxClients) || !IsClientInGame(client))
        return false;
    TFClassType class = GetNativeCell(2);
    if (class == TFClass_Unknown)
        return false;
    int slot = GetNativeCell(3);
    if (!(0 <= slot < WEAPONS_LENGTH))
        return false;
    char name[NAME_LENGTH];
    GetNativeString(4, name, sizeof(name));

    // Toggle the definition for resupply.
    return GiveToNext(client, class, slot, name);
}

// Unequip whatever definition is in a certain slot for a certain class of a
// specific client, meaning they will no longer have a custom weapon equipped
// after resupply.
//
// Use the slot corresponding to what key you typically use to equip this weapon
// (starting from 0 for primary).
//
// Note to self: if cosmetic code is implemented, use 8 for cosmetics as slot
public any Native_WeaponManager_RemovePersistedDefinition(Handle plugin, int numParams)
{
    // Retrieve parameters.
    int client = GetNativeCell(1);
    if (!(1 <= client <= MaxClients) || !IsClientInGame(client))
        return false;
    TFClassType class = GetNativeCell(2);
    if (class == TFClass_Unknown)
        return false;
    int slot = GetNativeCell(3);
    if (!(0 <= slot < WEAPONS_LENGTH))
        return false;

    // Detoggle the definition and return to command.
    return RemovePersist(client, class, slot);
}

// Returns whether a specific definition is allowed for a certain class of a 
// specific slot.
// 
// Use the slot corresponding to what key you typically use to equip this weapon
// (starting from 0 for primary).
public any Native_WeaponManager_DefinitionAllowed(Handle plugin, int numParams)
{
    // Retrieve parameters.
    char name[NAME_LENGTH];
    GetNativeString(1, name, sizeof(name));
    TFClassType class = GetNativeCell(2);
    if (class == TFClass_Unknown)
        return false;
    int slot = GetNativeCell(3);
    if (!(0 <= slot < WEAPONS_LENGTH))
        return false;
    
    // Get the definition, check whether the item def is allowed and return.
    Definition definition = ResolveDefinitionByName(name);
    if (definition == NULL_DEFINITION)
        return false;
    definition_t def;
    definition.Get(def);
    return IsDefinitionAllowed(def, class, slot);
}

// Returns whether a specific item definition index is allowed for a certain class
// of a specific slot.
// 
// Use the slot corresponding to what key you typically use to equip this weapon
// (starting from 0 for primary).
public any Native_WeaponManager_DefinitionAllowedByItemDef(Handle plugin, int numParams)
{
    // Retrieve parameters.
    int itemdef = GetNativeCell(1);
    TFClassType class = GetNativeCell(2);
    if (class == TFClass_Unknown)
        return false;
    int slot = GetNativeCell(3);
    if (!(0 <= slot < WEAPONS_LENGTH))
        return false;
    
    // Get the definition, check whether the item def is allowed and return.
    if (!g_DefinitionsByIndex[itemdef].m_bToggled)
        return false;
    definition_t def;
    view_as<Definition>(g_DefinitionsByIndex[itemdef].m_Object).Get(def);
    return IsDefinitionAllowed(def, class, slot);
}

// Retrieve the first weapon found in a specific slot.
// 
// Use the slot corresponding to what key you typically use to equip this weapon
// (starting from 0 for primary).
public any Native_WeaponManager_GetWeapon(Handle plugin, int numParams)
{
    // Retrieve parameters.
    int client = GetNativeCell(1);
    if (!(1 <= client <= MaxClients) || !IsClientInGame(client))
        return INVALID_ENT_REFERENCE;
    int slot = GetNativeCell(2);
    if (!(0 <= slot < WEAPONS_LENGTH))
        return INVALID_ENT_REFERENCE;

    // Get player data, retrieve the weapon from the slot and return.
    PlayerData data = PlayerData(client);
    Inventory inventory = data.GetInventory();
    Slot slotdata = inventory.GetSlot(slot);
    return slotdata.GetWeapon(.aliveonly = true);
}

// Retrieve a client's slot's replacement weapon.
// 
// Use the slot corresponding to what key you typically use to equip this weapon
// (starting from 0 for primary).
public any Native_WeaponManager_GetReplacementWeapon(Handle plugin, int numParams)
{
    // Retrieve parameters.
    int client = GetNativeCell(1);
    if (!(1 <= client <= MaxClients) || !IsClientInGame(client))
        return INVALID_ENT_REFERENCE;
    int slot = GetNativeCell(2);
    if (!(0 <= slot < WEAPONS_LENGTH))
        return INVALID_ENT_REFERENCE;

    // Get player data, retrieve the weapon from the slot and return.
    PlayerData data = PlayerData(client);
    Inventory inventory = data.GetInventory();
    Slot slotdata = inventory.GetSlot(slot);
    return ((!IsValidEntity(slotdata.m_hReplacement)) ? INVALID_ENT_REFERENCE : EntRefToEntIndex(slotdata.m_hReplacement));
}

// Retrieve a client's slot's fake slot replacement weapon. These weapons are used
// to allow a client to equip a weapon in another slot, as they will otherwise be equipped
// in their internal slot.
// 
// Use the slot corresponding to what key you typically use to equip this weapon
// (starting from 0 for primary).
public any Native_WeaponManager_GetFakeSlotReplacementWeapon(Handle plugin, int numParams)
{
    // Retrieve parameters.
    int client = GetNativeCell(1);
    if (!(1 <= client <= MaxClients) || !IsClientInGame(client))
        return INVALID_ENT_REFERENCE;
    int slot = GetNativeCell(2);
    if (!(0 <= slot < WEAPONS_LENGTH))
        return INVALID_ENT_REFERENCE;

    // Get player data, retrieve the weapon from the slot and return.
    PlayerData data = PlayerData(client);
    Inventory inventory = data.GetInventory();
    Slot slotdata = inventory.GetSlot(slot);
    return ((!IsValidEntity(slotdata.m_hFakeSlotReplacement)) ? INVALID_ENT_REFERENCE : EntRefToEntIndex(slotdata.m_hFakeSlotReplacement));
}

// Returns the internal TF2 slot of a weapon entity.
public any Native_WeaponManager_GetSlotOfWeapon(Handle plugin, int numParams)
{
    // Retrieve parameters.
    int weapon = GetNativeCell(1);
    if (!IsValidEdict(weapon))
        return TF_ITEMDEF_DEFAULT;
    TFClassType class = GetNativeCell(2);

    // Return the slot of this weapon.
    return GetItemLoadoutSlotOfWeapon(weapon, class);
}

// Returns whether a specific definition is allowed for a certain class of a 
// specific slot for Medieval mode.
public any Native_WeaponManager_MedievalMode_DefinitionAllowed(Handle plugin, int numParams)
{
    // Retrieve parameters.
    char name[NAME_LENGTH];
    GetNativeString(1, name, sizeof(name));
    TFClassType class = GetNativeCell(2);
    if (class == TFClass_Unknown)
        return false;
    
    // Get the definition, check whether the item def is allowed and return.
    Definition definition = ResolveDefinitionByName(name);
    if (definition == NULL_DEFINITION)
        return false;
    definition_t def;
    definition.Get(def);
    return IsDefinitionAllowedInMedievalMode(def, class);
}

// Returns whether a specific item definition index is allowed for a certain class
// of a specific slot for Medieval mode.
public any Native_WeaponManager_MedievalMode_DefinitionAllowedByItemDef(Handle plugin, int numParams)
{
    // Retrieve parameters.
    int itemdef = GetNativeCell(1);
    TFClassType class = GetNativeCell(2);
    if (class == TFClass_Unknown)
        return false;
    
    // Get the definition, check whether the item def is allowed and return.
    if (!g_DefinitionsByIndex[itemdef].m_bToggled)
        return false;
    definition_t def;
    view_as<Definition>(g_DefinitionsByIndex[itemdef].m_Object).Get(def);
    return IsDefinitionAllowedInMedievalMode(def, class);
}