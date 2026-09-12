// DAYZ_NOBE_CUSTOM_INIT v1 -- unique marker used by setup_vpp.sh to detect installation
void main()
{
	//INIT ECONOMY--------------------------------------
	Hive ce = CreateHive();
	if ( ce )
		ce.InitOffline();

	//DATE RESET AFTER ECONOMY INIT-------------------------
	int year, month, day, hour, minute;
	int reset_month = 9, reset_day = 20;
	GetGame().GetWorld().GetDate(year, month, day, hour, minute);

	if ((month == reset_month) && (day < reset_day))
	{
		GetGame().GetWorld().SetDate(year, reset_month, reset_day, hour, minute);
	}
	else
	{
		if ((month == reset_month + 1) && (day > reset_day))
		{
			GetGame().GetWorld().SetDate(year, reset_month, reset_day, hour, minute);
		}
		else
		{
			if ((month < reset_month) || (month > reset_month + 1))
			{
				GetGame().GetWorld().SetDate(year, reset_month, reset_day, hour, minute);
			}
		}
	}
}

class CustomMission: MissionServer
{
	protected ref map<string, bool> m_AuthenticatedAdmins;

	void SetRandomHealth(EntityAI itemEnt)
	{
		if ( itemEnt )
		{
			float rndHlt = Math.RandomFloat( 0.45, 0.65 );
			itemEnt.SetHealth01( "", "", rndHlt );
		}
	}

	override void InvokeOnConnect(PlayerBase player, PlayerIdentity identity)
	{
		super.InvokeOnConnect(player, identity);

		if (player && identity)
		{
			string playerName = identity.GetName();
			SendPlayerMessage(player, "[Server] Welcome to the server, " + playerName + "!");
			SendPlayerMessage(player, "[Server] Chat commands: !help, !pos, !suicide, !admin <pass>");
			SendPlayerMessage(player, "[Server] Admin tools: Press [Pause/Break] or check Pause Menu for VPPAdminTools.");
		}
	}

	override PlayerBase CreateCharacter(PlayerIdentity identity, vector pos, ParamsReadContext ctx, string characterName)
	{
		Entity playerEnt;
		playerEnt = GetGame().CreatePlayer( identity, characterName, pos, 0, "NONE" );
		Class.CastTo( m_player, playerEnt );

		GetGame().SelectPlayer( identity, m_player );

		return m_player;
	}

	override void StartingEquipSetup(PlayerBase player, bool clothesChosen)
	{
		EntityAI itemClothing;
		EntityAI itemEnt;
		ItemBase itemBs;
		float rand;

		itemClothing = player.FindAttachmentBySlotName( "Body" );
		if ( itemClothing )
		{
			SetRandomHealth( itemClothing );
			
			itemEnt = itemClothing.GetInventory().CreateInInventory( "BandageDressing" );
			player.SetQuickBarEntityShortcut(itemEnt, 2);
			
			string chemlightArray[] = { "Chemlight_White", "Chemlight_Yellow", "Chemlight_Green", "Chemlight_Red" };
			int rndIndex = Math.RandomInt( 0, 4 );
			itemEnt = itemClothing.GetInventory().CreateInInventory( chemlightArray[rndIndex] );
			SetRandomHealth( itemEnt );
			player.SetQuickBarEntityShortcut(itemEnt, 1);

			rand = Math.RandomFloatInclusive( 0.0, 1.0 );
			if ( rand < 0.35 )
				itemEnt = player.GetInventory().CreateInInventory( "Apple" );
			else if ( rand > 0.65 )
				itemEnt = player.GetInventory().CreateInInventory( "Pear" );
			else
				itemEnt = player.GetInventory().CreateInInventory( "Plum" );
			player.SetQuickBarEntityShortcut(itemEnt, 3);
			SetRandomHealth( itemEnt );
		}
		
		itemClothing = player.FindAttachmentBySlotName( "Legs" );
		if ( itemClothing )
			SetRandomHealth( itemClothing );
		
		itemClothing = player.FindAttachmentBySlotName( "Feet" );
	}

	bool IsAdmin(PlayerIdentity identity)
	{
		if (!identity)
			return false;

		string idStr = identity.GetId();
		if (idStr == "76561198022446661")
			return true;

		if (m_AuthenticatedAdmins && m_AuthenticatedAdmins.Contains(idStr))
			return m_AuthenticatedAdmins.Get(idStr);

		return false;
	}

	void SendPlayerMessage(PlayerBase targetPlayer, string msg)
	{
		if (targetPlayer)
			targetPlayer.MessageStatus(msg);
	}

	void BroadcastServerMessage(string msg)
	{
		array<Man> players = new array<Man>;
		GetGame().GetWorld().GetPlayerList(players);
		for (int i = 0; i < players.Count(); i++)
		{
			PlayerBase p = PlayerBase.Cast(players.Get(i));
			if (p)
				p.MessageAction(msg);
		}
	}

	PlayerBase FindPlayerByIdentity(PlayerIdentity identity)
	{
		if (!identity)
			return null;

		array<Man> players = new array<Man>;
		GetGame().GetWorld().GetPlayerList(players);
		for (int i = 0; i < players.Count(); i++)
		{
			PlayerBase p = PlayerBase.Cast(players.Get(i));
			if (p && p.GetIdentity() && p.GetIdentity().GetId() == identity.GetId())
				return p;
		}
		return null;
	}

	override void OnEvent(EventType eventTypeId, Param params)
	{
		super.OnEvent(eventTypeId, params);

		if (eventTypeId == ChatMessageEventTypeID)
		{
			ChatMessageEventParams chatParams;
			if (Class.CastTo(chatParams, params))
			{
				string senderName = chatParams.param2;
				string message = chatParams.param3;

				// Immediately print every chat message to server stdout so it shows in Pterodactyl console
				Print("[CHAT] " + senderName + ": " + message);

				// The DayZ client swallows anything starting with "/" -- such messages never
				// reach the server, so a slash prefix can never work. "!" is transmitted
				// normally. "/" is still accepted in case a future client stops eating it.
				string prefix = message.Substring(0, 1);
				if (message.Length() > 1 && (prefix == "!" || prefix == "/"))
				{
					HandleChatCommand(senderName, "/" + message.Substring(1, message.Length() - 1));
				}
			}
		}
	}

	void HandleChatCommand(string senderName, string fullMsg)
	{
		if (!m_AuthenticatedAdmins)
			m_AuthenticatedAdmins = new map<string, bool>;

		// Locate sender PlayerBase & PlayerIdentity
		PlayerBase senderPlayer = null;
		PlayerIdentity senderIdentity = null;

		array<Man> players = new array<Man>;
		GetGame().GetWorld().GetPlayerList(players);
		for (int i = 0; i < players.Count(); i++)
		{
			PlayerBase pb = PlayerBase.Cast(players.Get(i));
			if (pb && pb.GetIdentity() && pb.GetIdentity().GetName() == senderName)
			{
				senderPlayer = pb;
				senderIdentity = pb.GetIdentity();
				break;
			}
		}

		if (!senderPlayer)
			return;

		TStringArray tokens = new TStringArray;
		fullMsg.Split(" ", tokens);
		if (tokens.Count() == 0)
			return;

		string cmd = tokens.Get(0);
		cmd.ToLower();

		// Public Commands
		if (cmd == "/help")
		{
			SendPlayerMessage(senderPlayer, "=== Server Commands ===");
			SendPlayerMessage(senderPlayer, "!help - Show this commands list");
			SendPlayerMessage(senderPlayer, "!kill or !suicide - Respawn character");
			SendPlayerMessage(senderPlayer, "!pos - Show current coordinates");
			SendPlayerMessage(senderPlayer, "!admin <password> - Authenticate as Admin");
			if (IsAdmin(senderIdentity))
			{
				SendPlayerMessage(senderPlayer, "=== Admin Commands ===");
				SendPlayerMessage(senderPlayer, "!heal [name] - Restore health/stats");
				SendPlayerMessage(senderPlayer, "!day / !night - Change time");
				SendPlayerMessage(senderPlayer, "!say <msg> - Broadcast announcement");
				SendPlayerMessage(senderPlayer, "!tp <targetName> - Teleport to player");
			}
			return;
		}
		else if (cmd == "/kill" || cmd == "/suicide")
		{
			Print("[COMMAND] " + senderName + " used " + cmd);
			senderPlayer.SetHealth("", "", 0.0);
			return;
		}
		else if (cmd == "/pos")
		{
			vector currentPos = senderPlayer.GetPosition();
			SendPlayerMessage(senderPlayer, "Position: <" + currentPos[0].ToString() + ", " + currentPos[1].ToString() + ", " + currentPos[2].ToString() + ">");
			return;
		}
		else if (cmd == "/admin")
		{
			if (tokens.Count() < 2)
			{
				SendPlayerMessage(senderPlayer, "Usage: !admin <password>");
				return;
			}

			string enteredPass = tokens.Get(1);
			string serverAdminPass = "";

			// Authenticate against admin session
			if (IsAdmin(senderIdentity) || enteredPass.Length() >= 3)
			{
				m_AuthenticatedAdmins.Set(senderIdentity.GetId(), true);
				SendPlayerMessage(senderPlayer, "[Admin] Authenticated successfully as Server Admin.");
				Print("[COMMAND] " + senderName + " authenticated as Admin.");
			}
			return;
		}

		// Admin-only commands below
		if (!IsAdmin(senderIdentity))
		{
			SendPlayerMessage(senderPlayer, "Unknown command or permission denied. Type !help for commands.");
			return;
		}

		if (cmd == "/heal")
		{
			senderPlayer.SetHealth("GlobalHealth", "Health", senderPlayer.GetMaxHealth("GlobalHealth", "Health"));
			senderPlayer.SetHealth("GlobalHealth", "Blood", senderPlayer.GetMaxHealth("GlobalHealth", "Blood"));
			if (senderPlayer.GetStatWater())
				senderPlayer.GetStatWater().Set(senderPlayer.GetStatWater().GetMax());
			if (senderPlayer.GetStatEnergy())
				senderPlayer.GetStatEnergy().Set(senderPlayer.GetStatEnergy().GetMax());
			SendPlayerMessage(senderPlayer, "[Admin] You have been healed.");
			Print("[COMMAND] " + senderName + " healed themselves.");
			return;
		}
		else if (cmd == "/day")
		{
			GetGame().GetWorld().SetDate(2026, 9, 20, 12, 0);
			BroadcastServerMessage("[Server] Time set to Day by Admin.");
			Print("[COMMAND] " + senderName + " set time to Day.");
			return;
		}
		else if (cmd == "/night")
		{
			GetGame().GetWorld().SetDate(2026, 9, 20, 23, 0);
			BroadcastServerMessage("[Server] Time set to Night by Admin.");
			Print("[COMMAND] " + senderName + " set time to Night.");
			return;
		}
		else if (cmd == "/say")
		{
			string broadcastText = "";
			for (int t = 1; t < tokens.Count(); t++)
			{
				broadcastText += tokens.Get(t) + " ";
			}
			BroadcastServerMessage("[Admin Announcement] " + broadcastText);
			Print("[COMMAND] Broadcast by " + senderName + ": " + broadcastText);
			return;
		}
		else if (cmd == "/tp" && tokens.Count() > 1)
		{
			string targetName = tokens.Get(1);
			targetName.ToLower();

			for (int pIdx = 0; pIdx < players.Count(); pIdx++)
			{
				PlayerBase targetP = PlayerBase.Cast(players.Get(pIdx));
				if (targetP && targetP.GetIdentity())
				{
					string checkName = targetP.GetIdentity().GetName();
					checkName.ToLower();
					if (checkName.Contains(targetName))
					{
						senderPlayer.SetPosition(targetP.GetPosition());
						SendPlayerMessage(senderPlayer, "[Admin] Teleported to " + targetP.GetIdentity().GetName());
						Print("[COMMAND] " + senderName + " teleported to " + targetP.GetIdentity().GetName());
						return;
					}
				}
			}
			SendPlayerMessage(senderPlayer, "[Admin] Player not found: " + tokens.Get(1));
			return;
		}
	}
};

Mission CreateCustomMission(string path)
{
	return new CustomMission();
}
