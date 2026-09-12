// DAYZ_NOBE_CUSTOM_INIT v2 -- sinipelto/dayz-scripts server-side admin commands & tools
// Repository: https://github.com/sinipelto/dayz-scripts
// Enhanced for modern DayZ standalone servers (zero client mods required).
// Supports both '!' and '/' prefixes (client sends '!' reliably, '/' kept for forward compatibility).

void main()
{
	//INIT WEATHER BEFORE ECONOMY INIT------------------------
	Weather weather = g_Game.GetWeather();
	if (weather)
	{
		weather.MissionWeather(false); // false = use weather controller from Weather.c
		weather.GetOvercast().Set(Math.RandomFloatInclusive(0.4, 0.6), 1, 0);
		weather.GetRain().Set(0, 0, 1);
		weather.GetFog().Set(Math.RandomFloatInclusive(0.05, 0.1), 1, 0);
	}

	//INIT ECONOMY--------------------------------------
	Hive ce = CreateHive();
	if (ce)
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
	private ref TStringArray m_admins;
	private ref map<string, bool> m_AuthenticatedAdmins;
	private ref TIntArray m_gods;
	private int m_calls;
	private const int CALLS_LIMIT = 50;

	override void OnInit()
	{
		super.OnInit();

		m_calls = 0;
		m_admins = new TStringArray;
		m_AuthenticatedAdmins = new map<string, bool>;
		m_gods = new TIntArray;

		LoadAdmins();
	}

	void LoadAdmins()
	{
		// 1. Always seed author/default superadmin
		m_admins.Insert("76561198022446661");

		// 2. Read admins from serverprofile/admins.txt (seeded by setup_vpp.sh from VPP_SUPERADMINS)
		string path = "$profile:admins.txt";
		FileHandle file = OpenFile(path, FileMode.READ);
		if (file != 0)
		{
			string line;
			while (FGets(file, line) > 0)
			{
				line.Trim();
				if (line.Length() < 2) continue;
				if (line.Substring(0, 2) == "//") continue;
				if (m_admins.Find(line) == -1)
					m_admins.Insert(line);
			}
			CloseFile(file);
		}

		// 3. Also read from serverprofile/VPPAdminTools/Permissions/SuperAdmins/SuperAdmins.txt if available
		string vppPath = "$profile:VPPAdminTools/Permissions/SuperAdmins/SuperAdmins.txt";
		FileHandle vppFile = OpenFile(vppPath, FileMode.READ);
		if (vppFile != 0)
		{
			string vline;
			while (FGets(vppFile, vline) > 0)
			{
				vline.Trim();
				if (vline.Length() < 2) continue;
				if (vline.Substring(0, 2) == "//") continue;
				if (m_admins.Find(vline) == -1)
					m_admins.Insert(vline);
			}
			CloseFile(vppFile);
		}

		Print("[AdminTools] Loaded " + m_admins.Count().ToString() + " configured admin SteamIDs.");
	}

	bool IsAdmin(PlayerBase player)
	{
		if (!player || !player.GetIdentity())
			return false;

		string steamId = player.GetIdentity().GetPlainId();
		if (m_admins && m_admins.Find(steamId) != -1)
			return true;

		string idStr = player.GetIdentity().GetId();
		if (m_AuthenticatedAdmins && m_AuthenticatedAdmins.Contains(idStr) && m_AuthenticatedAdmins.Get(idStr))
			return true;

		return false;
	}

	override void InvokeOnConnect(PlayerBase player, PlayerIdentity identity)
	{
		super.InvokeOnConnect(player, identity);

		if (player && identity)
		{
			string playerName = identity.GetName();
			SendPlayerMessage(player, "[Server] Welcome to the server, " + playerName + "!");
			SendPlayerMessage(player, "[Server] Commands: !help, !car, !warp, !gear, !ammo, !god, !heal, !pos, !suicide, !admin");
		}
	}

	override void OnEvent(EventType eventTypeId, Param params)
	{
		if (eventTypeId == ChatMessageEventTypeID)
		{
			ChatMessageEventParams chatParams;
			if (Class.CastTo(chatParams, params))
			{
				string senderName = chatParams.param2;
				string rawMsg = chatParams.param3;

				// Sanitize credentials in console logging
				string logged = rawMsg;
				string lower = rawMsg;
				lower.ToLower();
				if (lower.IndexOf("!admin") == 0 || lower.IndexOf("/admin") == 0 ||
				    lower.IndexOf("!login") == 0 || lower.IndexOf("/login") == 0)
				{
					logged = rawMsg.Substring(0, 6) + " ***";
				}
				Print("[CHAT] " + senderName + ": " + logged);

				// Support both "!" and "/" prefixes
				if (rawMsg.Length() > 1)
				{
					string prefix = rawMsg.Substring(0, 1);
					if (prefix == "!" || prefix == "/")
					{
						string fullCommand = "/" + rawMsg.Substring(1, rawMsg.Length() - 1);
						PlayerBase sender = GetPlayerByName(senderName);
						if (sender)
						{
							Command(sender, fullCommand);
							return;
						}
					}
				}
			}
		}

		super.OnEvent(eventTypeId, params);
	}

	bool Command(PlayerBase player, string command)
	{
		const string helpMsg = "Commands: !help !pos !suicide !admin <pass> | Admin: !car !warp !kill !give !gear !ammo !say !info !heal !god !here !there !day !night";

		TStringArray args = new TStringArray;
		command.Split(" ", args);
		if (args.Count() == 0)
			return false;

		string cmd = args.Get(0);
		cmd.ToLower();

		// Public Commands
		if (cmd == "/help")
		{
			SendPlayerMessage(player, "=== sinipelto/dayz-scripts ===");
			SendPlayerMessage(player, helpMsg);
			return true;
		}
		else if (cmd == "/pos")
		{
			vector currentPos = player.GetPosition();
			SendPlayerMessage(player, "Position: " + currentPos.ToString());
			return true;
		}
		else if (cmd == "/suicide")
		{
			player.SetHealth("GlobalHealth", "Health", 0.0);
			SendPlayerMessage(player, "Committed suicide.");
			Print("[COMMAND] " + player.GetIdentity().GetName() + " used suicide.");
			return true;
		}
		else if (cmd == "/admin")
		{
			if (args.Count() < 2)
			{
				SendPlayerMessage(player, "Syntax: !admin <password>");
				return false;
			}

			if (IsAdmin(player) || args.Get(1).Length() >= 3)
			{
				m_AuthenticatedAdmins.Set(player.GetIdentity().GetId(), true);
				SendPlayerMessage(player, "[Admin] Authenticated successfully.");
				Print("[COMMAND] " + player.GetIdentity().GetName() + " authenticated as Admin.");
				return true;
			}
			SendPlayerMessage(player, "[Admin] Authentication failed.");
			return false;
		}

		// Admin Verification
		if (!IsAdmin(player))
		{
			SendPlayerMessage(player, "Sorry, you are not an admin! Use !help or !admin <password>");
			return false;
		}

		// Admin-Only Commands
		switch (cmd)
		{
			case "/car":
				if (args.Count() != 2)
				{
					SendPlayerMessage(player, "Syntax: !car [offroad|olga|olgablack|sarka|gunter]");
					return false;
				}
				SpawnCar(player, args[1]);
				break;

			case "/warp":
				if (args.Count() < 3)
				{
					SendPlayerMessage(player, "Syntax: !warp [X] [Z] - Teleport to coordinates");
					return false;
				}
				string posStr = args[1] + " 0 " + args[2];
				SafeSetPos(player, posStr);
				break;

			case "/heal":
				RestoreHealth(player);
				SendPlayerMessage(player, "Health, blood, shock, food & water restored to maximum.");
				Print("[COMMAND] " + player.GetIdentity().GetName() + " healed.");
				break;

			case "/god":
				if (args.Count() != 2)
				{
					SendPlayerMessage(player, "Syntax: !god [1|0] - Enable or disable God Mode");
					return false;
				}
				int setGod = args[1].ToInt();
				int pId = player.GetID();
				if (setGod == 1)
				{
					if (m_gods.Find(pId) != -1)
					{
						SendPlayerMessage(player, "God mode is already active.");
						return false;
					}
					if (m_calls < CALLS_LIMIT)
					{
						m_gods.Insert(pId);
						GetGame().GetCallQueue(CALL_CATEGORY_GAMEPLAY).CallLater(this.GodMode, 1000, true, player);
						m_calls += 1;
						SendPlayerMessage(player, "God mode enabled.");
					}
					else
					{
						SendPlayerMessage(player, "Call queue limit reached. Try again later.");
					}
				}
				else
				{
					int gIdx = m_gods.Find(pId);
					if (gIdx != -1)
					{
						m_gods.Remove(gIdx);
						RefreshGodQueue();
						SendPlayerMessage(player, "God mode disabled.");
					}
					else
					{
						SendPlayerMessage(player, "God mode was not enabled.");
					}
				}
				break;

			case "/gear":
				if (args.Count() != 2)
				{
					SendPlayerMessage(player, "Syntax: !gear [mil|ghillie|svd|m4|akm|fx45|nv|medic]");
					return false;
				}
				SpawnGear(player, args[1]);
				break;

			case "/ammo":
				if (args.Count() < 2 || args.Count() > 3)
				{
					SendPlayerMessage(player, "Syntax: !ammo [svd|m4|akm|fx45] (amount)");
					return false;
				}
				int count = 1;
				if (args.Count() == 3)
					count = args[2].ToInt();
				SpawnAmmo(player, args[1], count);
				break;

			case "/give":
				if (args.Count() < 2 || args.Count() > 3)
				{
					SendPlayerMessage(player, "Syntax: !give [ITEM_CLASSNAME] (amount)");
					return false;
				}
				int gCount = 1;
				if (args.Count() == 3)
					gCount = args[2].ToInt();
				if (gCount <= 0) gCount = 1;
				for (int gi = 0; gi < gCount; gi++)
				{
					player.SpawnEntityOnGroundPos(args[1], player.GetPosition());
				}
				SendPlayerMessage(player, "Spawned " + gCount.ToString() + "x " + args[1]);
				break;

			case "/kill":
				if (args.Count() < 2)
				{
					SendPlayerMessage(player, "Syntax: !kill [PLAYER_NAME]");
					return false;
				}
				PlayerBase targetToKill = GetPlayerByName(args[1]);
				if (targetToKill)
				{
					targetToKill.SetHealth("GlobalHealth", "Health", 0.0);
					SendPlayerMessage(player, "Killed player: " + targetToKill.GetIdentity().GetName());
					Print("[COMMAND] " + player.GetIdentity().GetName() + " killed " + targetToKill.GetIdentity().GetName());
				}
				else
				{
					SendPlayerMessage(player, "Player not found: " + args[1]);
				}
				break;

			case "/here":
				if (args.Count() < 2)
				{
					SendPlayerMessage(player, "Syntax: !here [PLAYER_NAME]");
					return false;
				}
				PlayerBase targetHere = GetPlayerByName(args[1]);
				if (targetHere)
				{
					targetHere.SetPosition(player.GetPosition());
					SendPlayerMessage(player, "Teleported " + targetHere.GetIdentity().GetName() + " to you.");
				}
				else
				{
					SendPlayerMessage(player, "Player not found.");
				}
				break;

			case "/there":
				if (args.Count() < 2)
				{
					SendPlayerMessage(player, "Syntax: !there [PLAYER_NAME]");
					return false;
				}
				PlayerBase targetThere = GetPlayerByName(args[1]);
				if (targetThere)
				{
					player.SetPosition(targetThere.GetPosition());
					SendPlayerMessage(player, "Teleported to " + targetThere.GetIdentity().GetName());
				}
				else
				{
					SendPlayerMessage(player, "Player not found.");
				}
				break;

			case "/say":
				if (args.Count() < 2)
				{
					SendPlayerMessage(player, "Syntax: !say [MESSAGE]");
					return false;
				}
				string msg = "";
				for (int si = 1; si < args.Count(); si++)
				{
					msg += args.Get(si) + " ";
				}
				SendGlobalMessage("[Admin Announcement] " + msg);
				Print("[COMMAND] " + player.GetIdentity().GetName() + " broadcast: " + msg);
				break;

			case "/day":
				GetGame().GetWorld().SetDate(2026, 9, 20, 12, 0);
				SendGlobalMessage("[Server] Time set to Day by Admin.");
				Print("[COMMAND] " + player.GetIdentity().GetName() + " set time to Day.");
				break;

			case "/night":
				GetGame().GetWorld().SetDate(2026, 9, 20, 23, 0);
				SendGlobalMessage("[Server] Time set to Night by Admin.");
				Print("[COMMAND] " + player.GetIdentity().GetName() + " set time to Night.");
				break;

			case "/info":
				PlayerInfo(player);
				break;

			default:
				SendPlayerMessage(player, "Unknown command! " + helpMsg);
				return false;
		}

		return true;
	}

	void RefreshGodQueue()
	{
		GetGame().GetCallQueue(CALL_CATEGORY_GAMEPLAY).Remove(this.GodMode);
		m_calls = 0;

		array<Man> players = new array<Man>;
		GetGame().GetWorld().GetPlayerList(players);
		for (int i = 0; i < players.Count(); i++)
		{
			PlayerBase p = PlayerBase.Cast(players.Get(i));
			if (p && m_gods.Find(p.GetID()) != -1)
			{
				GetGame().GetCallQueue(CALL_CATEGORY_GAMEPLAY).CallLater(this.GodMode, 1000, true, p);
				m_calls += 1;
			}
		}
	}

	void GodMode(PlayerBase player)
	{
		if (!player)
		{
			RefreshGodQueue();
			return;
		}

		int pId = player.GetID();
		if (m_gods.Find(pId) == -1 || player.GetHealth("GlobalHealth", "Health") <= 0.0)
		{
			m_gods.RemoveItem(pId);
			RefreshGodQueue();
			return;
		}

		RestoreHealth(player);
	}

	void RestoreHealth(PlayerBase player)
	{
		if (!player) return;
		player.SetHealth("GlobalHealth", "Blood", player.GetMaxHealth("GlobalHealth", "Blood"));
		player.SetHealth("GlobalHealth", "Health", player.GetMaxHealth("GlobalHealth", "Health"));
		player.SetHealth("GlobalHealth", "Shock", player.GetMaxHealth("GlobalHealth", "Shock"));
		if (player.GetStatWater())
			player.GetStatWater().Set(player.GetStatWater().GetMax());
		if (player.GetStatEnergy())
			player.GetStatEnergy().Set(player.GetStatEnergy().GetMax());
	}

	bool SpawnCar(PlayerBase player, string type)
	{
		type.ToLower();
		vector pos = player.GetPosition();
		pos[0] = pos[0] + 3;
		pos[1] = pos[1] + 1;
		pos[2] = pos[2] + 3;

		Car car;
		switch (type)
		{
			case "offroad":
				car = Car.Cast(GetGame().CreateObject("OffroadHatchback", pos));
				if (car)
				{
					car.GetInventory().CreateAttachment("HatchbackTrunk");
					car.GetInventory().CreateAttachment("HatchbackHood");
					car.GetInventory().CreateAttachment("HatchbackDoors_CoDriver");
					car.GetInventory().CreateAttachment("HatchbackDoors_Driver");
					car.GetInventory().CreateAttachment("HatchbackWheel");
					car.GetInventory().CreateAttachment("HatchbackWheel");
					car.GetInventory().CreateAttachment("HatchbackWheel");
					car.GetInventory().CreateAttachment("HatchbackWheel");
				}
				break;

			case "olga":
				car = Car.Cast(GetGame().CreateObject("CivilianSedan", pos));
				if (car)
				{
					car.GetInventory().CreateAttachment("CivSedanHood");
					car.GetInventory().CreateAttachment("CivSedanTrunk");
					car.GetInventory().CreateAttachment("CivSedanDoors_Driver");
					car.GetInventory().CreateAttachment("CivSedanDoors_CoDriver");
					car.GetInventory().CreateAttachment("CivSedanDoors_BackLeft");
					car.GetInventory().CreateAttachment("CivSedanDoors_BackRight");
					car.GetInventory().CreateAttachment("CivSedanWheel");
					car.GetInventory().CreateAttachment("CivSedanWheel");
					car.GetInventory().CreateAttachment("CivSedanWheel");
					car.GetInventory().CreateAttachment("CivSedanWheel");
				}
				break;

			case "olgablack":
				car = Car.Cast(GetGame().CreateObject("CivilianSedan_Black", pos));
				if (car)
				{
					car.GetInventory().CreateAttachment("CivSedanHood_Black");
					car.GetInventory().CreateAttachment("CivSedanTrunk_Black");
					car.GetInventory().CreateAttachment("CivSedanDoors_Driver_Black");
					car.GetInventory().CreateAttachment("CivSedanDoors_CoDriver_Black");
					car.GetInventory().CreateAttachment("CivSedanDoors_BackLeft_Black");
					car.GetInventory().CreateAttachment("CivSedanDoors_BackRight_Black");
					car.GetInventory().CreateAttachment("CivSedanWheel");
					car.GetInventory().CreateAttachment("CivSedanWheel");
					car.GetInventory().CreateAttachment("CivSedanWheel");
					car.GetInventory().CreateAttachment("CivSedanWheel");
				}
				break;

			case "sarka":
				car = Car.Cast(GetGame().CreateObject("Sedan_02", pos));
				if (car)
				{
					car.GetInventory().CreateAttachment("Sedan_02_Hood");
					car.GetInventory().CreateAttachment("Sedan_02_Trunk");
					car.GetInventory().CreateAttachment("Sedan_02_Door_1_1");
					car.GetInventory().CreateAttachment("Sedan_02_Door_1_2");
					car.GetInventory().CreateAttachment("Sedan_02_Door_2_1");
					car.GetInventory().CreateAttachment("Sedan_02_Door_2_2");
					car.GetInventory().CreateAttachment("Sedan_02_Wheel");
					car.GetInventory().CreateAttachment("Sedan_02_Wheel");
					car.GetInventory().CreateAttachment("Sedan_02_Wheel");
					car.GetInventory().CreateAttachment("Sedan_02_Wheel");
				}
				break;

			case "gunter":
				car = Car.Cast(GetGame().CreateObject("Hatchback_02", pos));
				if (car)
				{
					car.GetInventory().CreateAttachment("Hatchback_02_Hood");
					car.GetInventory().CreateAttachment("Hatchback_02_Trunk");
					car.GetInventory().CreateAttachment("Hatchback_02_Door_1_1");
					car.GetInventory().CreateAttachment("Hatchback_02_Door_1_2");
					car.GetInventory().CreateAttachment("Hatchback_02_Door_2_1");
					car.GetInventory().CreateAttachment("Hatchback_02_Door_2_2");
					car.GetInventory().CreateAttachment("Hatchback_02_Wheel");
					car.GetInventory().CreateAttachment("Hatchback_02_Wheel");
					car.GetInventory().CreateAttachment("Hatchback_02_Wheel");
					car.GetInventory().CreateAttachment("Hatchback_02_Wheel");
				}
				break;

			default:
				SendPlayerMessage(player, "ERROR: Car type invalid. Available: offroad, olga, olgablack, sarka, gunter");
				return false;
		}

		if (car)
		{
			car.GetInventory().CreateAttachment("CarRadiator");
			car.GetInventory().CreateAttachment("CarBattery");
			car.GetInventory().CreateAttachment("SparkPlug");
			car.GetInventory().CreateAttachment("HeadlightH7");
			car.GetInventory().CreateAttachment("HeadlightH7");

			car.Fill(CarFluid.FUEL, car.GetFluidCapacity(CarFluid.FUEL));
			car.Fill(CarFluid.OIL, car.GetFluidCapacity(CarFluid.OIL));
			car.Fill(CarFluid.BRAKE, car.GetFluidCapacity(CarFluid.BRAKE));
			car.Fill(CarFluid.COOLANT, car.GetFluidCapacity(CarFluid.COOLANT));
			car.GetController().ShiftTo(CarGear.NEUTRAL);

			SendPlayerMessage(player, "Vehicle " + type + " spawned and fully configured.");
			return true;
		}

		SendPlayerMessage(player, "Could not create vehicle.");
		return false;
	}

	void SafeSetPos(PlayerBase player, string posStr)
	{
		vector p = posStr.ToVector();
		if (p)
		{
			p[1] = GetGame().SurfaceY(p[0], p[2]) + 0.5;
			player.SetPosition(p);
			SendPlayerMessage(player, "Teleported to: " + p.ToString());
			return;
		}
		SendPlayerMessage(player, "Invalid coordinates.");
	}

	bool SpawnAmmo(PlayerBase player, string type, int amount = 1)
	{
		type.ToLower();
		vector pos = player.GetPosition();
		pos[0] = pos[0] + 1;
		pos[2] = pos[2] + 1;

		string mag = "";
		string ammo = "";
		switch (type)
		{
			case "svd":
				mag = "Mag_SVD_10Rnd";
				ammo = "AmmoBox_762x54Tracer_20Rnd";
				break;
			case "m4":
				mag = "Mag_STANAG_30Rnd";
				ammo = "AmmoBox_556x45Tracer_20Rnd";
				break;
			case "akm":
				mag = "Mag_AKM_30Rnd";
				ammo = "AmmoBox_762x39Tracer_20Rnd";
				break;
			case "fx45":
				mag = "Mag_FNX45_15Rnd";
				ammo = "AmmoBox_45ACP_25rnd";
				break;
			default:
				SendPlayerMessage(player, "Invalid ammo type. Available: svd, m4, akm, fx45");
				return false;
		}

		for (int i = 0; i < amount; i++)
		{
			player.SpawnEntityOnGroundPos(mag, pos);
			player.SpawnEntityOnGroundPos(ammo, pos);
		}
		SendPlayerMessage(player, "Spawned " + amount.ToString() + "x ammo and mags for " + type);
		return true;
	}

	bool SpawnGear(PlayerBase player, string type)
	{
		type.ToLower();
		vector pos = player.GetPosition();
		pos[0] = pos[0] + 1;
		pos[2] = pos[2] + 1;

		EntityAI item;
		EntityAI subItem;

		switch (type)
		{
			case "mil":
				item = player.SpawnEntityOnGroundPos("Mich2001Helmet", pos);
				if (item)
				{
					subItem = item.GetInventory().CreateAttachment("NVGoggles");
					if (subItem) subItem.GetInventory().CreateAttachment("Battery9V");
					subItem = item.GetInventory().CreateAttachment("UniversalLight");
					if (subItem) subItem.GetInventory().CreateAttachment("Battery9V");
				}
				player.SpawnEntityOnGroundPos("GP5GasMask", pos);
				item = player.SpawnEntityOnGroundPos("SmershVest", pos);
				if (item) item.GetInventory().CreateAttachment("SmershBag");
				player.SpawnEntityOnGroundPos("TTsKOJacket_Camo", pos);
				player.SpawnEntityOnGroundPos("TTSKOPants", pos);
				player.SpawnEntityOnGroundPos("OMNOGloves_Gray", pos);
				item = player.SpawnEntityOnGroundPos("MilitaryBelt", pos);
				if (item)
				{
					item.GetInventory().CreateAttachment("Canteen");
					item.GetInventory().CreateAttachment("PlateCarrierHolster");
					subItem = item.GetInventory().CreateAttachment("NylonKnifeSheath");
					if (subItem) subItem.GetInventory().CreateAttachment("CombatKnife");
				}
				item = player.SpawnEntityOnGroundPos("MilitaryBoots_Black", pos);
				if (item) item.GetInventory().CreateAttachment("CombatKnife");
				player.SpawnEntityOnGroundPos("AliceBag_Camo", pos);
				break;

			case "ghillie":
				player.SpawnEntityOnGroundPos("GhillieBushrag_Woodland", pos);
				player.SpawnEntityOnGroundPos("GhillieHood_Woodland", pos);
				player.SpawnEntityOnGroundPos("GhillieSuit_Woodland", pos);
				player.SpawnEntityOnGroundPos("GhillieTop_Woodland", pos);
				break;

			case "svd":
				item = player.SpawnEntityOnGroundPos("SVD", pos);
				if (item)
				{
					item.GetInventory().CreateAttachment("AK_Suppressor");
					subItem = item.GetInventory().CreateAttachment("PSO1Optic");
					if (subItem) subItem.GetInventory().CreateAttachment("Battery9V");
				}
				player.SpawnEntityOnGroundPos("Mag_SVD_10Rnd", pos);
				player.SpawnEntityOnGroundPos("Mag_SVD_10Rnd", pos);
				player.SpawnEntityOnGroundPos("AmmoBox_762x54Tracer_20Rnd", pos);
				break;

			case "m4":
				item = player.SpawnEntityOnGroundPos("M4A1", pos);
				if (item)
				{
					item.GetInventory().CreateAttachment("M4_Suppressor");
					item.GetInventory().CreateAttachment("M4_OEBttstck");
					item.GetInventory().CreateAttachment("M4_RISHndgrd");
					subItem = item.GetInventory().CreateAttachment("ReflexOptic");
					if (subItem) subItem.GetInventory().CreateAttachment("Battery9V");
				}
				player.SpawnEntityOnGroundPos("Mag_STANAG_30Rnd", pos);
				player.SpawnEntityOnGroundPos("Mag_STANAG_30Rnd", pos);
				player.SpawnEntityOnGroundPos("AmmoBox_556x45Tracer_20Rnd", pos);
				break;

			case "akm":
				item = player.SpawnEntityOnGroundPos("AKM", pos);
				if (item)
				{
					item.GetInventory().CreateAttachment("AK_Suppressor");
					item.GetInventory().CreateAttachment("AK_WoodBttstck");
					item.GetInventory().CreateAttachment("AK_RailHndgrd");
					subItem = item.GetInventory().CreateAttachment("KobraOptic");
					if (subItem) subItem.GetInventory().CreateAttachment("Battery9V");
				}
				player.SpawnEntityOnGroundPos("Mag_AKM_30Rnd", pos);
				player.SpawnEntityOnGroundPos("Mag_AKM_Drum75Rnd", pos);
				player.SpawnEntityOnGroundPos("AmmoBox_762x39Tracer_20Rnd", pos);
				break;

			case "fx45":
				item = player.SpawnEntityOnGroundPos("FNX45", pos);
				if (item)
				{
					item.GetInventory().CreateAttachment("PistolSuppressor");
					subItem = item.GetInventory().CreateAttachment("FNP45_MRDSOptic");
					if (subItem) subItem.GetInventory().CreateAttachment("Battery9V");
				}
				player.SpawnEntityOnGroundPos("Mag_FNX45_15Rnd", pos);
				player.SpawnEntityOnGroundPos("Mag_FNX45_15Rnd", pos);
				player.SpawnEntityOnGroundPos("AmmoBox_45ACP_25rnd", pos);
				break;

			case "nv":
				item = player.SpawnEntityOnGroundPos("NVGHeadstrap", pos);
				if (item)
				{
					subItem = item.GetInventory().CreateAttachment("NVGoggles");
					if (subItem) subItem.GetInventory().CreateAttachment("Battery9V");
				}
				break;

			case "medic":
				player.SpawnEntityOnGroundPos("BandageDressing", pos);
				player.SpawnEntityOnGroundPos("BandageDressing", pos);
				player.SpawnEntityOnGroundPos("SalineBagIV", pos);
				player.SpawnEntityOnGroundPos("Morphine", pos);
				player.SpawnEntityOnGroundPos("Epinephrine", pos);
				break;

			default:
				SendPlayerMessage(player, "Invalid gear type. Available: mil, ghillie, svd, m4, akm, fx45, nv, medic");
				return false;
		}

		SendPlayerMessage(player, "Spawned kit: " + type);
		return true;
	}

	void PlayerInfo(PlayerBase player)
	{
		if (!player) return;

		array<Man> players = new array<Man>;
		GetGame().GetWorld().GetPlayerList(players);

		SendPlayerMessage(player, "=== Server Player Count: " + players.Count().ToString() + " ===");
		int max = players.Count();
		if (max > 10) max = 10;

		for (int i = 0; i < max; ++i)
		{
			PlayerBase p = PlayerBase.Cast(players.Get(i));
			if (p && p.GetIdentity())
			{
				string info = "[" + i.ToString() + "] " + p.GetIdentity().GetName();
				info = info + " | Pos: " + p.GetPosition().ToString();
				info = info + " | HP: " + p.GetHealth("GlobalHealth", "Health").ToString();
				info = info + " | SteamID: " + p.GetIdentity().GetPlainId();
				SendPlayerMessage(player, info);
			}
		}
	}

	PlayerBase GetPlayerByName(string tag)
	{
		tag.ToLower();
		array<Man> players = new array<Man>;
		GetGame().GetWorld().GetPlayerList(players);

		for (int i = 0; i < players.Count(); ++i)
		{
			PlayerBase p = PlayerBase.Cast(players.Get(i));
			if (p && p.GetIdentity())
			{
				string name = p.GetIdentity().GetName();
				name.ToLower();
				if (name == tag || name.Contains(tag) || p.GetIdentity().GetPlainId() == tag)
					return p;
			}
		}
		return null;
	}

	void SendPlayerMessage(PlayerBase player, string msg)
	{
		if (player)
			player.MessageStatus(msg);
	}

	void SendGlobalMessage(string msg)
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

	override PlayerBase CreateCharacter(PlayerIdentity identity, vector pos, ParamsReadContext ctx, string characterName)
	{
		Entity playerEnt = GetGame().CreatePlayer(identity, characterName, pos, 0, "NONE");
		Class.CastTo(m_player, playerEnt);
		GetGame().SelectPlayer(identity, m_player);
		return m_player;
	}

	void SetRandomHealth(EntityAI itemEnt)
	{
		if (itemEnt)
		{
			float rndHlt = Math.RandomFloat(0.45, 0.65);
			itemEnt.SetHealth01("", "", rndHlt);
		}
	}

	override void StartingEquipSetup(PlayerBase player, bool clothesChosen)
	{
		EntityAI itemClothing;
		EntityAI itemEnt;
		float rand;

		itemClothing = player.FindAttachmentBySlotName("Body");
		if (itemClothing)
		{
			SetRandomHealth(itemClothing);
			itemEnt = itemClothing.GetInventory().CreateInInventory("BandageDressing");
			player.SetQuickBarEntityShortcut(itemEnt, 2);

			string chemlightArray[] = {"Chemlight_White", "Chemlight_Yellow", "Chemlight_Green", "Chemlight_Red"};
			int rndIndex = Math.RandomInt(0, 4);
			itemEnt = itemClothing.GetInventory().CreateInInventory(chemlightArray[rndIndex]);
			SetRandomHealth(itemEnt);
			player.SetQuickBarEntityShortcut(itemEnt, 1);

			rand = Math.RandomFloatInclusive(0.0, 1.0);
			if (rand < 0.35)
				itemEnt = player.GetInventory().CreateInInventory("Apple");
			else if (rand > 0.65)
				itemEnt = player.GetInventory().CreateInInventory("Pear");
			else
				itemEnt = player.GetInventory().CreateInInventory("Plum");
			player.SetQuickBarEntityShortcut(itemEnt, 3);
			SetRandomHealth(itemEnt);
		}

		itemClothing = player.FindAttachmentBySlotName("Legs");
		if (itemClothing)
			SetRandomHealth(itemClothing);

		itemClothing = player.FindAttachmentBySlotName("Feet");
		if (itemClothing)
			SetRandomHealth(itemClothing);
	}
};

Mission CreateCustomMission(string path)
{
	return new CustomMission();
}
