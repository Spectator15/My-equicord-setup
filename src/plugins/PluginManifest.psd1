@{
    SchemaVersion = 1
    Plugins = @(
        @{
            Id = "smoothType"
            DisplayName = "SmoothType"
            FolderName = "smoothType"
            Description = "Smooth animated caret for Discord's message input."
            DefaultSelected = $true
            LegacyFolders = @("SmoothType")
            Notes = "Uses DOM selection listeners with cleanup."
            Files = @("index.tsx")
        }
        @{
            Id = "streamerModeOnStream"
            DisplayName = "StreamerModeOnStream"
            FolderName = "streamerModeOnStream"
            Description = "Automatically enables streamer mode while you stream."
            DefaultSelected = $true
            LegacyFolders = @("StreamerModeOnStream")
            Notes = "Uses declarative Flux events."
            Files = @("index.ts")
        }
        @{
            Id = "exportDM"
            DisplayName = "ExportDM"
            FolderName = "exportDM"
            Description = "Exports messages as JSON, online HTML, an offline ZIP archive, or self-contained HTML."
            DefaultSelected = $true
            LegacyFolders = @("ExportDM")
            Notes = "Uses Discord REST pagination and bounded, cancellable media downloads."
            Files = @("index.tsx")
        }
        @{
            Id = "serverCloner"
            DisplayName = "ServerCloner"
            FolderName = "serverCloner"
            Description = "Clones server settings, roles, channels, icon, and emojis to another server."
            DefaultSelected = $true
            LegacyFolders = @("ServerCloner")
            Notes = "Uses Discord RestAPI and throttled clone steps."
            Files = @("index.tsx")
        }
        @{
            Id = "antiDeleteMessage"
            DisplayName = "AntiDeleteMessage"
            FolderName = "antiDeleteMessage"
            Description = "Locally resends your messages when someone deletes them."
            DefaultSelected = $true
            LegacyFolders = @("AntiDeleteMessage")
            Notes = "Bounded cache setting and cleared delayed resend timers."
            Files = @("index.ts")
        }
        @{
            Id = "lastSeen"
            DisplayName = "LastSeen"
            FolderName = "lastSeen"
            Description = "Shows a user's last observed activity in the profile panel."
            DefaultSelected = $true
            LegacyFolders = @("LastSeen")
            Notes = "Subscribes/unsubscribes Flux events explicitly."
            Files = @("index.tsx")
        }
        @{
            Id = "streamProof"
            DisplayName = "StreamProof"
            FolderName = "streamProof"
            Description = "Blurs sensitive Discord content while streaming until clicked."
            DefaultSelected = $true
            LegacyFolders = @("StreamProof")
            Notes = "Removes click listener, style tag, and reveal classes on stop."
            Files = @("index.tsx")
        }
        @{
            Id = "fakePerm"
            DisplayName = "FakePerm"
            FolderName = "fakePerm"
            Description = "Adds local-only fake moderation menu actions for visual testing."
            DefaultSelected = $true
            LegacyFolders = @("FakePerm")
            Notes = "Clears local state and fake timeout timers on disable/stop."
            Files = @("index.tsx")
        }
        @{
            Id = "fakeDM"
            DisplayName = "FakeDM"
            FolderName = "fakeDM"
            Description = "Injects local-only fake DM messages and calls through a chat bar panel."
            DefaultSelected = $true
            LegacyFolders = @("FakeDM")
            Notes = "Caps persisted entries and clears restore timers on stop."
            Files = @("index.tsx", "styles.css")
        }
        @{
            Id = "antiMoveDeco"
            DisplayName = "AntiMoveDeco"
            FolderName = "antiMoveDeco"
            Description = "Keeps you in the selected voice channel when moved or disconnected."
            DefaultSelected = $true
            LegacyFolders = @("AntiMoveDeco")
            Notes = "Uses VoiceStateStore and clears pending reconnect timers."
            Files = @("index.tsx")
        }
    )
}
