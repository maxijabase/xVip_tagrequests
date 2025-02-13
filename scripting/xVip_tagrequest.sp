#include <sourcemod>
#include <morecolors>
#include <ccc>
#include <xVip>

#pragma semicolon 1
#pragma newdecls required

Database g_DB;
StringMap g_Players;
bool g_Late;
bool g_Spawned[MAXPLAYERS];

public Plugin myinfo = {
  name = "xVip - Tag Request", 
  author = "ampere", 
  description = "Allows players to submit a CCC tag request for admins to approve or deny.", 
  version = "1.0", 
  url = "github.com/maxijabase"
}

enum struct Request {
  char steamid[32];
  char name[MAX_NAME_LENGTH];
  char oldtag[32];
  char newtag[32];
  int timestamp;
  char state[16];
}

ArrayList g_Requests;
Request g_SelectedRequest;

// ======= [FORWARDS] ======= //

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max) {
  g_Late = late;
  return APLRes_Success;
}

public void OnPluginStart() {
  Database.Connect(SQL_Connection, "xVip");
  
  HookEvent("player_team", OnClientJoinTeam);
  
  RegConsoleCmd("sm_tagrequest", CMD_TagRequest, "Makes a tag change request.");
  RegAdminCmd("sm_tagrequests", CMD_SeeTagRequests, ADMFLAG_GENERIC, "Lists all the tag requests.");
  
  LoadTranslations("common.phrases");
  LoadTranslations("xVip_tagrequest.phrases");
  
  g_Requests = new ArrayList(sizeof(Request));
  g_Players = new StringMap();
  
  if (g_Late) {
    for (int i = 1; i <= MaxClients; i++) {
      if (IsClientConnected(i)) {
        OnClientPostAdminCheck(i);
      }
    }
  }
}

public void OnMapStart() {
  CacheRequests();
}

public void OnClientPostAdminCheck(int client) {
  g_Spawned[client] = false;
  
  char steamid[32], userid[64];
  GetClientAuthId(client, AuthId_Steam2, steamid, sizeof(steamid));
  IntToString(GetClientUserId(client), userid, sizeof(userid));
  g_Players.SetString(userid, steamid);
}

public void OnClientDisconnect(int client) {
  char userid[64];
  IntToString(GetClientUserId(client), userid, sizeof(userid));
  g_Players.Remove(userid);
  g_Spawned[client] = false;
}

public void OnClientJoinTeam(Event event, const char[] name, bool dontBroadcast) {
  int userid = event.GetInt("userid");
  int client = GetClientOfUserId(event.GetInt("userid"));
  if (g_Spawned[client]) {
    return;
  }
  CheckPendingMessages(userid);
  g_Spawned[client] = true;
}

// ======= [COMMANDS] ======= //

public Action CMD_TagRequest(int client, int args) {
  if (!xVip_IsVip(client)) {
    xVip_Reply(client, "%t", "NotVip");
    return Plugin_Handled;
  }

  if (args == 0) {
    xVip_Reply(client, "Usage: sm_tagrequest <tag>");
    return Plugin_Handled;
  }
  
  char userid[64], steamid[32];
  IntToString(GetClientUserId(client), userid, sizeof(userid));
  g_Players.GetString(userid, steamid, sizeof(steamid));
  
  char requestedTag[32];
  for (int i = 1; i <= GetCmdArgs(); i++) {
    char buffer[32];
    GetCmdArg(i, buffer, sizeof(buffer));
    Format(buffer, sizeof(buffer), "%s ", buffer);
    StrCat(requestedTag, sizeof(requestedTag), buffer);
  }
  
  char pendingTag[32];
  GetPendingTag(steamid, pendingTag, sizeof(pendingTag));
  if (pendingTag[0] != '\0') {
    xVip_Reply(client, "%t", "PendingRequest", pendingTag);
    return Plugin_Handled;
  }
  
  char currentTag[32];
  CCC_GetTag(client, currentTag, sizeof(currentTag));
  if (StrEqual(requestedTag, currentTag)) {
    xVip_Reply(client, "%t", "TagsAreEqual");
    return Plugin_Handled;
  }
  
  Request req;
  
  strcopy(req.steamid, sizeof(req.steamid), steamid);
  GetClientName(client, req.name, sizeof(req.name));
  strcopy(req.oldtag, sizeof(req.oldtag), currentTag);
  strcopy(req.newtag, sizeof(req.newtag), requestedTag);
  
  req.state = "pending";
  
  char query[256];
  g_DB.Format(query, sizeof(query), 
    "INSERT INTO xVip_tagrequests (steam_id, name, current_tag, desired_tag, timestamp, state) VALUES "...
    "('%s', '%s', '%s', '%s', UNIX_TIMESTAMP(), '%s')", req.steamid, req.name, req.oldtag, req.newtag, req.state);
  
  DataPack pack = new DataPack();
  pack.WriteCell(GetClientUserId(client));
  pack.WriteCellArray(req, sizeof(req));
  
  g_DB.Query(SQL_InsertRequest, query, pack);
  
  return Plugin_Handled;
}

public Action CMD_SeeTagRequests(int client, int args) {
  
  if (g_Requests.Length == 0) {
    xVip_Reply(client, "%t", "NoRequests");
  }
  else {
    CreateRequestsMenu(client);
  }
  
  return Plugin_Handled;
}

// ======= [METHODS] ======= //

void CacheRequests() {
  
  if (g_DB == null) {
    return;
  }
  
  g_Requests.Clear();
  
  char query[128];
  g_DB.Format(query, sizeof(query), "SELECT * FROM xVip_tagrequests WHERE state != 'finished'");
  
  g_DB.Query(SQL_CacheRequests, query);
}

void CreateRequestsMenu(int client) {
  Menu menu = new Menu(RequestsMenuHandler);
  menu.SetTitle("%t", "Str_TagRequests");
  
  for (int i = 0; i < g_Requests.Length; i++) {
    Request req;
    g_Requests.GetArray(i, req, sizeof(req));
    
    if (StrEqual(req.state, "pending")) {
      menu.AddItem(req.steamid, req.name);
    }
    
  }
  
  if (menu.ItemCount == 0) {
    xVip_Reply(client, "%t", "NoRequests");
    delete menu;
    return;
  }
  menu.ExitButton = true;
  menu.Display(client, MENU_TIME_FOREVER);
}

void GetPendingTag(const char[] steamid, char[] buffer, int maxsize) {
  for (int i = 0; i < g_Requests.Length; i++) {
    Request r;
    g_Requests.GetArray(i, r, sizeof(r));
    if (StrEqual(r.steamid, steamid) && !StrEqual(r.state, "finished")) {
      strcopy(buffer, maxsize, r.newtag);
    }
  }
}

void CheckPendingMessages(int userid) {
  char steamid[32], user_id[16];
  IntToString(userid, user_id, sizeof(user_id));
  g_Players.GetString(user_id, steamid, sizeof(steamid));
  
  int totalPendingRequests;
  int client = GetClientOfUserId(userid);
  
  for (int i = 0; i < g_Requests.Length; i++) {
    Request r;
    g_Requests.GetArray(i, r, sizeof(r));
    
    switch (r.state[0]) {
      case 'p': {
        totalPendingRequests++;
      }
      
      case 'd', 'a': {
        SendInfoPanel(userid, r.state);
        g_SelectedRequest = r;
        if (r.state[0] == 'a') {
          SetClientTag(r, userid);
        }
        UpdateRequest("finished", 0);
      }
    }
  }
  if (totalPendingRequests > 0 && CheckCommandAccess(client, "sm_admin", ADMFLAG_ROOT)) {
    xVip_Reply(client, "%t", "ThereArePendingRequests", client, totalPendingRequests);
  }
}

void UpdateRequest(char[] state, int userid) {
  if (g_DB == null) {
    return;
  }
  
  char query[256];
  g_DB.Format(query, sizeof(query), "UPDATE xVip_tagrequests SET state = '%s' WHERE steam_id = '%s' AND desired_tag = '%s'"...
    "ORDER BY id DESC LIMIT 1", state, g_SelectedRequest.steamid, g_SelectedRequest.newtag);
  
  DataPack pack = new DataPack();
  pack.WriteString(state);
  pack.WriteCell(userid);
  
  g_DB.Query(SQL_StatusUpdate, query, pack);
}

void SendInfoPanel(int userid, const char[] state) {
  
  int client = GetClientOfUserId(userid);
  
  Panel panel = new Panel();
  panel.SetTitle("Tag Request");
  char line1[64], phrase[16], exitStr[16];
  Format(phrase, sizeof(phrase), StrEqual(state, "approved") ? "TagApprovedUser" : "TagDeniedUser");
  Format(line1, sizeof(line1), "%t", phrase, g_SelectedRequest.newtag);
  Format(exitStr, sizeof(exitStr), "%t", "Str_Exit");
  panel.DrawText(line1);
  panel.DrawText(" ");
  panel.CurrentKey = 10;
  panel.DrawItem(exitStr);
  panel.Send(client, EmptyHandler, MENU_TIME_FOREVER);
}

void SetRequestState(const char[] steamid, const char[] state) {
  for (int i = 0; i < g_Requests.Length; i++) {
    Request r;
    g_Requests.GetArray(i, r, sizeof(r));
    if (StrEqual(r.steamid, steamid)) {
      if (StrEqual(state, "finished")) {
        g_Requests.Erase(i);
      }
      else {
        strcopy(r.state, sizeof(r.state), state);
        g_Requests.SetArray(i, r, sizeof(r));
      }
      return;
    }
  }
}

void ShowRequestDetailsPanel(int client) {
  Panel panel = new Panel();
  char panelTitle[32];
  Format(panelTitle, sizeof(panelTitle), "%t", "Str_ShowingTagRequestOfUser", g_SelectedRequest.name);
  panel.SetTitle(panelTitle);
  
  char line1[64], line2[64], line3[64], time[64];
  
  Format(line1, sizeof(line1), "%t", "Str_CurrentTag", g_SelectedRequest.oldtag);
  Format(line2, sizeof(line2), "%t", "Str_NewTag", g_SelectedRequest.newtag);
  FormatTime(time, sizeof(time), "%b %d, %Y %R", g_SelectedRequest.timestamp);
  Format(line3, sizeof(line3), "%t", "Str_DateRequested", time);
  panel.DrawText(" ");
  panel.DrawText(line1);
  panel.DrawText(line2);
  panel.DrawText(line3);
  panel.DrawText(" ");
  
  char approve[32], deny[32], back[16], exitStr[16];
  
  Format(approve, sizeof(approve), "%t", "Str_ApproveTag");
  Format(deny, sizeof(deny), "%t", "Str_DenyTag");
  Format(back, sizeof(back), "%t", "Str_Back");
  Format(exitStr, sizeof(exitStr), "%t", "Str_Exit");
  panel.DrawItem(approve);
  panel.DrawItem(deny);
  panel.CurrentKey = 9;
  panel.DrawItem(back);
  panel.DrawItem(exitStr);
  
  panel.Send(client, RequestDetailsPanelHandler, MENU_TIME_FOREVER);
}

void SetClientTag(Request r, int userid) {
  char query[256];
  int client = GetClientOfUserId(userid);
  g_DB.Format(query, sizeof(query), "INSERT INTO cccm_users (auth, tagtext) VALUES ('%s', '%s') ON DUPLICATE KEY UPDATE tagtext = '%s'", r.steamid, r.newtag, r.newtag);
  CCC_SetTag(client, r.newtag);
  g_DB.Query(SQL_SetTag, query);
}

// ======= [MENU HANDLERS] ======= //

public int RequestsMenuHandler(Menu menu, MenuAction action, int client, int param2) {
  switch (action) {
    case MenuAction_Select: {
      g_Requests.GetArray(param2, g_SelectedRequest, sizeof(g_SelectedRequest));
      ShowRequestDetailsPanel(client);
    }
    case MenuAction_End: {
      delete menu;
    }
  }
  return 0;
}

public int RequestDetailsPanelHandler(Menu menu, MenuAction action, int param1, int param2) {
  switch (action) {
    case MenuAction_Select: {
      switch (param2) {
        case 1: {
          UpdateRequest("approved", GetClientUserId(param1));
        }
        case 2: {
          UpdateRequest("denied", GetClientUserId(param1));
        }
        case 9: {
          CreateRequestsMenu(param1);
        }
        case 10: {
          delete menu;
        }
      }
    }
    case MenuAction_End: {
      delete menu;
    }
  }
  return 0;
}

public int EmptyHandler(Menu menu, MenuAction action, int param1, int param2) { return 0; }

// ======= [SQL CALLBACKS] ======= //

public void SQL_SetTag(Database db, DBResultSet results, const char[] error, any data) {
  if (db == null || results == null || error[0] != '\0') {
    LogError("SQL_SetTag callback: %s", error);
    return;
  }
}

public void SQL_StatusUpdate(Database db, DBResultSet results, const char[] error, DataPack pack) {
  if (db == null || results == null || error[0] != '\0') {
    LogError("StatusUpdate callback: %s", error);
    return;
  }
  
  pack.Reset();
  char state[16];
  pack.ReadString(state, sizeof(state));
  int admin_client = GetClientOfUserId(pack.ReadCell());
  delete pack;
  
  SetRequestState(g_SelectedRequest.steamid, state);
  
  char phrase[32];
  if (StrEqual(state, "approved")) {
    strcopy(phrase, sizeof(phrase), "TagApprovedAdmin");
    int userid = GetUserIDBySteamID(g_SelectedRequest.steamid);
    int client = GetClientOfUserId(userid);
    if (IsValidClient(client)) {
      CCC_SetTag(client, g_SelectedRequest.newtag);
    }
  }
  else if (StrEqual(state, "denied")) {
    strcopy(phrase, sizeof(phrase), "TagDeniedAdmin");
  }
  if (admin_client != 0) {
    xVip_Reply(admin_client, "%t", phrase, g_SelectedRequest.newtag);
    CreateRequestsMenu(admin_client);
  }
}

public void SQL_CacheRequests(Database db, DBResultSet results, const char[] error, any data) {
  if (db == null || results == null || error[0] != '\0') {
    LogError("Cache requests callback: %s", error);
    return;
  }
  
  if (results.RowCount == 0) {
    return;
  }
  
  int steamidCol, nameCol, currtagCol, wantedtagCol, timestampCol, stateCol;
  results.FieldNameToNum("steam_id", steamidCol);
  results.FieldNameToNum("name", nameCol);
  results.FieldNameToNum("current_tag", currtagCol);
  results.FieldNameToNum("desired_tag", wantedtagCol);
  results.FieldNameToNum("timestamp", timestampCol);
  results.FieldNameToNum("state", stateCol);
  
  while (results.FetchRow()) {
    Request req;
    results.FetchString(steamidCol, req.steamid, sizeof(req.steamid));
    results.FetchString(nameCol, req.name, sizeof(req.name));
    results.FetchString(currtagCol, req.oldtag, sizeof(req.oldtag));
    results.FetchString(wantedtagCol, req.newtag, sizeof(req.newtag));
    req.timestamp = results.FetchInt(timestampCol);
    results.FetchString(stateCol, req.state, sizeof(req.state));
    
    g_Requests.PushArray(req);
  }
}

public void SQL_Connection(Database db, const char[] error, any data) {
  if (db == null) {
    SetFailState("Connection: %s", error);
    return;
  }
  
  g_DB = db;
  char tablesQuery[256] = 
  "CREATE TABLE IF NOT EXISTS xVip_tagrequests "...
  "(id INT NOT NULL AUTO_INCREMENT, "...
  "steam_id VARCHAR(32), "...
  "name VARCHAR(32), "...
  "current_tag VARCHAR(32), "...
  "desired_tag VARCHAR(32), "...
  "timestamp int, "...
  "state VARCHAR(32), "...
  "PRIMARY KEY(id));";
  
  g_DB.Query(SQL_Tables, tablesQuery);
}

public void SQL_Tables(Database db, DBResultSet results, const char[] error, any data) {
  if (db == null || error[0] != '\0') {
    LogError("Tables callback: %s", error);
    return;
  }
  if (results.AffectedRows > 0) {
    LogMessage("Tables creation successful.");
  }
}

public void SQL_InsertRequest(Database db, DBResultSet results, const char[] error, DataPack pack) {
  pack.Reset();
  int client = GetClientOfUserId(pack.ReadCell());
  Request req;
  pack.ReadCellArray(req, sizeof(req));
  delete pack;
  
  if (db == null || error[0] != '\0') {
    LogError("Insert request callback for %N: %s", client, error);
    return;
  }
  
  g_Requests.PushArray(req);
  xVip_Reply(client, "%t", "RequestSent", req.newtag);
  
  delete results;
} 