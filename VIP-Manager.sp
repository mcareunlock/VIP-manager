#include <sourcemod>

#define Version "2.1"

Database connection;

Handle onAddVIPForward;
Handle onRemoveVIPForward;
Handle onDurationChangedForward;

public Plugin myinfo = {
	name = "VIP-Manager",
	author = "Shadow_Man",
	description = "Manage VIPs on your server",
	version = Version,
	url = "http://cf-server.pfweb.eu"
};

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, err_max)
{
	RegPluginLibrary("VIP-Manager");

	return APLRes_Success;
}

public void OnPluginStart()
{
	CreateConVar("sm_vipm_version", Version, "Version of VIP-Manager", FCVAR_PLUGIN | FCVAR_SPONLY);

	RegAdminCmd("sm_vipm", Cmd_PrintHelp, ADMFLAG_ROOT, "Lists all commands.");
	RegAdminCmd("sm_vipm_add", Cmd_AddVIP, ADMFLAG_ROOT, "Add a VIP.");
	RegAdminCmd("sm_vipm_rm", CmdRemoveVIP, ADMFLAG_ROOT, "Remove a VIP.");
	RegAdminCmd("sm_vipm_time", CmdChangeVIPTime, ADMFLAG_ROOT, "Change the duration for a VIP.");
	RegAdminCmd("sm_vipm_check", CmdCheckVIPs, ADMFLAG_ROOT, "Check for expired VIPs.");

	onAddVIPForward = CreateGlobalForward("OnVIPAdded", ET_Ignore, Param_Cell, Param_String, Param_String, Param_Cell);
	onRemoveVIPForward = CreateGlobalForward("OnVIPRemoved", ET_Ignore, Param_Cell, Param_String, Param_String, Param_String);
	onDurationChangedForward = CreateGlobalForward("OnVIPDurationChanged", ET_Ignore, Param_Cell, Param_String, Param_String, Param_String, Param_Cell, Param_Cell);

	ConnectToDatabase();
}

public Action Cmd_PrintHelp(int client, int args)
{
	ReplyToCommand(client, "sm_vipm | Lists all commands.");
	ReplyToCommand(client, "sm_vipm_add <\"name\"> <minutes> [\"SteamId\"] | Add a VIP. If SteamID is give, it will be used.");
	ReplyToCommand(client, "sm_vipm_rm <\"name\"> | Remove a VIP");
	ReplyToCommand(client, "sm_vipm_time <set|add|sub> <\"name\"> <minutes> | Change the duration for a VIP.");
	ReplyToCommand(client, "sm_vipm_check | Checks for expired VIPs.");

	return Plugin_Handled;
}

public Action Cmd_AddVIP(int client, int args)
{
	if(connection == null) {
		ReplyToCommand(client, "There is currently no connection to the SQL server");
		return Plugin_Handled;
	}

	if(args < 2) {
		ReplyToCommand(client, "Usage: sm_vipm_add <\"name\"> <minutes> [\"SteamId\"]");
		return Plugin_Handled;
	}

	char name[64];
	char steamId[64];

	if(args == 2) {
		char searchName[64];
		GetCmdArg(1, searchName, sizeof(searchName));

		if(!SearchClient(searchName, name, sizeof(name), steamId, sizeof(steamId))) {
			ReplyToCommand(client, "Can't find client '%s'", searchName);
			return Plugin_Handled;
		}
	}
	else {
		GetCmdArg(1, name, sizeof(name));
		GetCmdArg(3, steamId, sizeof(steamId));
	}

	char durationString[16];
	GetCmdArg(2, durationString, sizeof(durationString));

	AddVIP(client, name, steamId, StringToInt(durationString));

	return Plugin_Handled;
}

void AddVIP(int caller, const char[] name, const char[] steamId, int duration)
{
	int len = strlen(name) * 2 + 1;
	char[] escapedName = new char[len];
	connection.Escape(name, escapedName, len);

	len = strlen(steamId) * 2 + 1;
	char[] escapedSteamId = new char[len];
	connection.Escape(steamId, escapedSteamId, len);

	if(duration < -1)
		duration = -1;

	DataPack pack = new DataPack();
	pack.WriteCell(caller);
	pack.WriteString(name);
	pack.WriteString(steamId);
	pack.WriteCell(duration);

	char query[512];
	Format(query, sizeof(query), "INSERT INTO vips (steamId, name, duration) VALUES ('%s', '%s', %i);", escapedSteamId, escapedName, duration);
	connection.Query(AddVIPCallback, query, pack);
}

public void AddVIPCallback(Database db, DBResultSet result, char[] error, any data)
{
	DataPack pack = view_as<DataPack>(data);
	pack.Reset();
	int caller = pack.ReadCell();

	if(result == null) {
		LogError("Error while adding VIP! Error: %s", error);
		ReplyClient(caller, "Can't add VIP! %s", error);
		return;
	}

	char name[64];
	pack.ReadString(name, sizeof(name));

	char steamId[64];
	pack.ReadString(steamId, sizeof(steamId));

	int duration = pack.ReadCell();

	int vipClient = FindPlayer(name);
	if(AddVIPToAdminCache(vipClient))
		ReplyClient(caller, "Successfully added '%s' as a VIP for %i minutes!", name, duration);
	else
		ReplyClient(caller, "Added '%s' as a VIP in database, but can't added VIP in admin cache!", name);

	Call_StartForward(onAddVIPForward);
	Call_PushCell(caller);
	Call_PushString(name);
	Call_PushString(steamId);
	Call_PushCell(duration);
	Call_Finish();
}

bool AddVIPToAdminCache(int client)
{
	if(!IsClientConnected(client))
		return false;

	char steamId[64];
	GetClientAuthId(client, AuthId_Engine, steamId, sizeof(steamId));

	AdminId admin = FindAdminByIdentity(AUTHMETHOD_STEAM, steamId);
	if(admin != INVALID_ADMIN_ID)
		RemoveAdmin(admin);

	GroupId group = FindAdmGroup("VIP");
	if(group == INVALID_GROUP_ID) {
		PrintToServer("[VIP-Manager] Couldn't found group 'VIP'! Please create a group called 'VIP'.");
		return false;
	}

	admin = CreateAdmin();
	AdminInheritGroup(admin, group);
	if(!BindAdminIdentity(admin, AUTHMETHOD_STEAM, steamId)) {
		RemoveAdmin(admin);
		return false;
	}

	RunAdminCacheChecks(client);
	return true;
}

public Action CmdRemoveVIP(int client, int args)
{
	if(connection == null)
	{
		ReplyToCommand(client, "There is currently no connection to the SQL server");
		return Plugin_Handled;
	}

	if(args < 1)
	{
		ReplyToCommand(client, "Usage: sm_vipm_rm <\"name\">");
		return Plugin_Handled;
	}

	char searchName[64];
	GetCmdArg(1, searchName, sizeof(searchName));

	char query[128];
	Format(query, sizeof(query), "SELECT * FROM vips WHERE name LIKE '%%%s%%';", searchName);

	DataPack pack = new DataPack();
	pack.WriteCell(client);
	pack.WriteString(searchName);

	connection.Query(CallbackPreRemoveVIP, query, pack);
	return Plugin_Handled;
}

public void CallbackPreRemoveVIP(Database db, DBResultSet result, char[] error, any data)
{
	DataPack pack = view_as<DataPack>(data);
	pack.Reset();
	int client = pack.ReadCell();

	if(result == null)
	{
		LogError("Error while selecting VIP for removing! Error: %s", error);
		ReplyClient(client, "Can't remove VIP! %s", error);
		return;
	}

	char searchName[64];
	pack.ReadString(searchName, sizeof(searchName));

	if(result.AffectedRows == 0)
	{
		ReplyClient(client, "Can't find a VIP with the name '%s'!", searchName);
		return;
	}
	else if(result.AffectedRows > 1)
	{
		ReplyClient(client, "Found more than one VIP with the name '%s'! Please specify the name more accurately!", searchName);
		return;
	}

	result.FetchRow();

	char steamId[64];
	result.FetchString(0, steamId, sizeof(steamId));

	char name[64];
	result.FetchString(1, name, sizeof(name));

	char adminName[64];
	GetClientName(client, adminName, sizeof(adminName));

	char reason[256];
	Format(reason, sizeof(reason), "Removed by admin '%s'", adminName);

	RemoveVip(client, steamId, name, reason);
}

void RemoveVip(int client, char[] steamId, char[] name, char[] reason)
{
	DataPack pack = new DataPack();
	pack.WriteCell(client);
	pack.WriteString(steamId);
	pack.WriteString(name);
	pack.WriteString(reason);

	int len = strlen(steamId) * 2 + 1;
	char[] escapedSteamId = new char[len];
	connection.Escape(steamId, escapedSteamId, len);

	char query[128];
	Format(query, sizeof(query), "DELETE FROM vips WHERE steamId = '%s';", escapedSteamId);
	connection.Query(CallbackRemoveVIP, query, pack);
}

public void CallbackRemoveVIP(Database db, DBResultSet result, char[] error, any data)
{
	DataPack pack = view_as<DataPack>(data);
	pack.Reset();

	int client = pack.ReadCell();

	if(result == null)
	{
		LogError("Error while removing VIP! Error: %s", error);
		if(client > 0)
			ReplyClient(client, "Can't remove VIP! %s", error);
		return;
	}

	char steamId[64];
	pack.ReadString(steamId, sizeof(steamId));

	char name[64];
	pack.ReadString(name, sizeof(name));

	char reason[256];
	pack.ReadString(reason, sizeof(reason));

	RemoveVipFromAdminCache(steamId);

	Call_StartForward(onRemoveVIPForward);
	Call_PushCell(client);
	Call_PushString(name);
	Call_PushString(steamId);
	Call_PushString(reason);
	Call_Finish();

	ReplyClient(client, "Removed VIP %s(%s)! Reason: %s", name, steamId, reason);
}

void RemoveVipFromAdminCache(char[] steamId)
{
	AdminId admin = FindAdminByIdentity(AUTHMETHOD_STEAM, steamId);
	if(admin == INVALID_ADMIN_ID)
		return;

	RemoveAdmin(admin);
}

public Action CmdChangeVIPTime(int client, int args)
{
	if(args != 3)
	{
		ReplyToCommand(client, "Usage: sm_vipm_time <set|add|sub> <\"name\"> <minutes>");
		return Plugin_Handled;
	}

	char mode[8];
	GetCmdArg(1, mode, sizeof(mode));

	if(!StrEqual(mode, "set", false) && !StrEqual(mode, "add", false) && !StrEqual(mode, "sub", false))
	{
		ReplyToCommand(client, "Unknown mode '%s'! Please use 'set', 'add' or 'sub'.", mode);
		return Plugin_Handled;
	}

	char searchName[64];
	GetCmdArg(2, searchName, sizeof(searchName));

	char minutesString[8];
	GetCmdArg(3, minutesString, sizeof(minutesString));

	int minutes = StringToInt(minutesString);
	if(minutes < 0)
		minutes *= -1;

	DataPack pack = new DataPack();
	pack.WriteCell(client);
	pack.WriteString(searchName);
	pack.WriteString(mode);
	pack.WriteCell(minutes);

	char query[128];
	Format(query, sizeof(query), "SELECT * FROM vips WHERE name LIKE '%%%s%%';", searchName);

	connection.Query(CallbackPreChangeTime, query, pack);
	return Plugin_Handled;
}

public void CallbackPreChangeTime(Database db, DBResultSet result, char[] error, any data)
{
	DataPack pack = view_as<DataPack>(data);
	pack.Reset();
	int client = pack.ReadCell();

	if(result == null)
	{
		LogError("Error while selecting VIP for time manipulation! Error: %s", error);
		ReplyClient(client, "Can't change time for VIP! %s", error);
		return;
	}

	char searchName[64];
	pack.ReadString(searchName, sizeof(searchName));

	if(result.AffectedRows == 0)
	{
		ReplyClient(client, "Can't find a VIP with the name '%s'!", searchName);
		return;
	}
	else if(result.AffectedRows > 1)
	{
		ReplyClient(client, "Found more than one VIP with the name '%s'! Please specify the name more accurately!", searchName);
		return;
	}

	result.FetchRow();

	char steamId[64];
	result.FetchString(0, steamId, sizeof(steamId));

	char name[64];
	result.FetchString(1, name, sizeof(name));

	int duration = result.FetchInt(3);

	char mode[8];
	pack.ReadString(mode, sizeof(mode));

	int newDuration;
	int minutes = pack.ReadCell();
	if(StrEqual(mode, "set", false))
		newDuration = minutes;
	else if(StrEqual(mode, "add"))
		newDuration = duration + minutes;
	else if(StrEqual(mode, "sub"))
		newDuration = duration - minutes;

	delete pack;
	pack = new DataPack();

	pack.WriteCell(client);
	pack.WriteString(name);
	pack.WriteString(steamId);
	pack.WriteString(mode);
	pack.WriteCell(duration);
	pack.WriteCell(newDuration);

	char query[128];
	Format(query, sizeof(query), "UPDATE vips SET duration = %i WHERE steamId = '%s'", newDuration, steamId);

	connection.Query(CallbackChangeTime, query, pack);
}

public void CallbackChangeTime(Database db, DBResultSet result, char[] error, any data)
{
	DataPack pack = view_as<DataPack>(data);
	pack.Reset();
	int client = pack.ReadCell();

	if(result == null)
	{
		LogError("Error while manipulate VIP time! Error: %s", error);
		ReplyClient(client, "Can't change time for VIP! %s", error);
		return;
	}

	char name[64];
	pack.ReadString(name, sizeof(name));

	char steamId[64];
	pack.ReadString(steamId, sizeof(steamId));

	char mode[8];
	pack.ReadString(mode, sizeof(mode));

	int duration = pack.ReadCell();
	int newDuration = pack.ReadCell();

	Call_StartForward(onDurationChangedForward);
	Call_PushCell(client);
	Call_PushString(name);
	Call_PushString(steamId);
	Call_PushString(mode);
	Call_PushCell(duration);
	Call_PushCell(newDuration);
	Call_Finish();

	ReplyClient(client, "Changed time for VIP '%s' from %i to %i minutes!", name, duration, newDuration);
}

public Action CmdCheckVIPs(int client, int args)
{
	DataPack pack = new DataPack();
	pack.WriteCell(client);

	char query[128];
	if(DriverIsSQLite())
		Format(query, sizeof(query), "SELECT * FROM vips WHERE (strftime('%%s', joindate, duration || ' minutes') - strftime('%%s', 'now')) < 0 AND duration >= 0;");
	else
		Format(query, sizeof(query), "SELECT * FROM vips WHERE TIMEDIFF(DATE_ADD(joindate, INTERVAL duration MINUTE), NOW()) < 0 AND duration >= 0;");

	connection.Query(CallbackCheckVIPs, query, pack);
	return Plugin_Handled;
}

public void CallbackCheckVIPs(Database db, DBResultSet result, char[] error, any data)
{
	DataPack pack = view_as<DataPack>(data);
	pack.Reset();
	int client = pack.ReadCell();

	if(result == null)
	{
		LogError("Error while checking VIPs! Error: %s", error);
		ReplyClient(client, "Can't check VIPs! %s", error);
		return;
	}

	if(result.AffectedRows <= 0)
	{
		ReplyClient(client, "No VIP is expired.");
		return;
	}

	while(result.FetchRow())
	{
		char steamId[64];
		result.FetchString(0, steamId, sizeof(steamId));

		char name[64];
		result.FetchString(1, name, sizeof(name));

		char reason[256];
		strcopy(reason, sizeof(reason), "Time expired!");

		RemoveVip(client, steamId, name, reason);
	}

	ReplyClient(client, "Removed all expired VIPs!");
}

void ConnectToDatabase()
{
	if(SQL_CheckConfig("vip-manager"))
		Database.Connect(CallbackConnect, "vip-manager");
	else
		Database.Connect(CallbackConnect, "default");
}

public void CallbackConnect(Database db, char[] error, any data)
{
	if(db == null)
		LogError("Can't connect to server. Error: %s", error);

	connection = db;
	CreateTableIfExists();
}

void CreateTableIfExists()
{
	if(connection == null)
		return;

	connection.Query(CallbackCreateTable, "CREATE TABLE IF NOT EXISTS vips (steamId VARCHAR(64) PRIMARY KEY, name VARCHAR(64) NOT NULL, joindate TIMESTAMP DEFAULT CURRENT_TIMESTAMP, duration INT(11) NOT NULL);");
}

public void CallbackCreateTable(Database db, DBResultSet result, char[] error, any data)
{
	if(result == null)
		LogError("Error while creating table! Error: %s", error);
}

public Action OnClientPreAdminCheck(int client)
{
	if(connection == null)
		return Plugin_Continue;

	if(GetUserAdmin(client) != INVALID_ADMIN_ID)
		return Plugin_Continue;

	CheckVIP(client);
	FetchVIP(client);
	return Plugin_Handled;
}

void CheckVIP(int client)
{
	if(connection == null)
		return;

	DataPack pack = new DataPack();

	char steamId[64];
	GetClientAuthId(client, AuthId_Engine, steamId, sizeof(steamId));
	pack.WriteString(steamId);

	char name[64];
	GetClientName(client, name, sizeof(name));
	pack.WriteString(name);

	int len = strlen(steamId) * 2 + 1;
	char[] escapedSteamId = new char[len];
	connection.Escape(steamId, escapedSteamId, len);

	char query[196];
	if(DriverIsSQLite())
		Format(query, sizeof(query), "SELECT joindate, duration FROM vips WHERE steamId = '%s' AND (strftime('%%s', joindate, duration || ' minutes') - strftime('%%s', 'now')) < 0 AND duration >= 0;", escapedSteamId);
	else
		Format(query, sizeof(query), "SELECT joindate, duration FROM vips WHERE steamId = '%s' AND TIMEDIFF(DATE_ADD(joindate, INTERVAL duration MINUTE), NOW()) < 0 AND duration >= 0;", escapedSteamId);

	connection.Query(CallbackCheckVIP, query, pack, DBPrio_High);
}

public void CallbackCheckVIP(Database db, DBResultSet result, char[] error, any data)
{
	if(result == null)
	{
		LogError("Error while checking VIP! Error: %s", error);
		return;
	}

	if(result.AffectedRows != 1)
		return;

	DataPack pack = view_as<DataPack>(data);
	pack.Reset();

	char steamId[64];
	pack.ReadString(steamId, sizeof(steamId));

	char name[64];
	pack.ReadString(name, sizeof(name));

	char reason[256];
	strcopy(reason, sizeof(reason), "Time expired!");

	RemoveVip(0, steamId, name, reason);
}

void FetchVIP(int client)
{
	char steamId[64];
	GetClientAuthId(client, AuthId_Engine, steamId, sizeof(steamId));

	int len = strlen(steamId) * 2 + 1;
	char[] escapedSteamId = new char[len];
	connection.Escape(steamId, escapedSteamId, len);

	char query[128];
	Format(query, sizeof(query), "SELECT duration FROM vips WHERE steamId = '%s';", escapedSteamId);
	connection.Query(CallbackFetchVIP, query, client, DBPrio_High);
}

public void CallbackFetchVIP(Database db, DBResultSet result, char[] error, any data)
{
	int client = data;

	if(result == null)
	{
		LogError("Error while fetching VIP! Error: %s", error);
		return;
	}

	if(result.AffectedRows != 1)
		return;

	AddVIPToAdminCache(client);
	NotifyPostAdminCheck(client);
}

public int OnRebuildAdminCache(AdminCachePart part)
{
	if(part == AdminCache_Admins)
		FetchAvailableVIPs();
}

void FetchAvailableVIPs()
{
	for(int i = 1; i < MaxClients; i++)
	{
		if(IsClientConnected(i) && GetUserAdmin(i) == INVALID_ADMIN_ID)
			FetchVIP(i);
	}
}

void ReplyClient(int client, const char[] format, any ...)
{
	int len = strlen(format) + 256;
	char[] message = new char[len];
	VFormat(message, len, format, 3);

	if(client == 0)
		PrintToServer(message);
	else
		PrintToChat(client, message);
}

bool DriverIsSQLite()
{
	DBDriver driver = connection.Driver;
	char identifier[64];
	driver.GetIdentifier(identifier, sizeof(identifier));

	return StrEqual(identifier, "sqlite");
}

bool SearchClient(const char[] search, char[] name, nameLength, char[] steamId, steamIdLength)
{
	int client = FindPlayer(search);
	if(client == -1)
		return false;

	GetClientName(client, name, nameLength);
	GetClientAuthId(client, AuthId_Engine, steamId, steamIdLength);
	return true;
}

int FindPlayer(const char[] searchTerm)
{
	for(int client = 1; client < MaxClients; client++) {
		if(ClientNameContainsString(client, searchTerm))
			return client;
	}

	return -1;
}

bool ClientNameContainsString(int client, const char[] str)
{
	if(!IsClientConnected(i))
		return false;

	char playerName[MAX_NAME_LENGTH];
	GetClientName(i, playerName, sizeof(playerName));

	return StrContains(playerName, searchTerm, false) > -1;
}
