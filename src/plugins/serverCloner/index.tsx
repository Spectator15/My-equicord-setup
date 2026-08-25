/*
 * Vencord, a Discord client mod
 * Copyright (c) 2026 Vendicated and contributors
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Modified for My Equicord Setup by Spectator15, 2026-08-15.
 * Original copyright and authorship remain with the respective upstream contributors.
 */

import { addContextMenuPatch, NavContextMenuPatchCallback, removeContextMenuPatch } from "@api/ContextMenu";
import { definePluginSettings } from "@api/Settings";
import { FormSwitch } from "@components/FormSwitch";
import { sleep } from "@utils/misc";
import definePlugin, { OptionType } from "@utils/types";
import type { RenderModalProps } from "@vencord/discord-types";
import { findStoreLazy } from "@webpack";
import { Button, Forms, GuildStore, IconUtils, Menu, Modal, openModal, React, RestAPI, Select, Toasts, useMemo, useRef, UserStore, useState } from "@webpack/common";

const F = Forms as any;
const PermissionStore = findStoreLazy("PermissionStore");
const ADMIN_BIT = 0x8n;

function hasAdmin(guildId: string): boolean { try { const guild = GuildStore.getGuild(guildId); if (!guild) return false; const me = UserStore.getCurrentUser(); if (guild.ownerId === me.id) return true; const perms = PermissionStore.getGuildPermissions({ id: guildId }); if (typeof perms === "bigint") return (perms & ADMIN_BIT) === ADMIN_BIT; return false; } catch { return false; } }
async function apiCall(method: "get" | "post" | "patch" | "put" | "del", url: string, body?: any): Promise<any> { const opts: any = { url }; if (body) opts.body = body; const res = await (RestAPI as any)[method](opts); const status = Number(res?.status ?? 200); if (res?.ok === false || status >= 400) throw new Error(res?.body?.message || `HTTP ${status}`); return res?.body; }
async function wait(ms: number) { await sleep(ms); }
function mapPermOverwrites(overwrites: any[], roleMapping: Map<string, string>): any[] { return overwrites.filter(ow => roleMapping.has(ow.id)).map(ow => ({ id: roleMapping.get(ow.id)!, type: ow.type, allow: String(ow.allow), deny: String(ow.deny) })); }

interface CloneOptions { roles: boolean; clearRoles: boolean; channels: boolean; noDeleteChannels: boolean; permissions: boolean; icon: boolean; emojis: boolean; guildSettings: boolean; }
interface LogEntry { text: string; type: "ok" | "err" | "warn" | "info"; }

let _running = false; let _cancelled = false; let _progress = 0; let _logs: LogEntry[] = [];
const MAX_LOG_ENTRIES = 1000;
const _listeners = new Set<() => void>();
function notifyListeners() { _listeners.forEach(fn => fn()); }
function persistLog(entry: LogEntry) { _logs = [..._logs, entry].slice(-MAX_LOG_ENTRIES); notifyListeners(); }
function persistProgress(p: number) { _progress = p; notifyListeners(); }
function persistRunning(v: boolean) { _running = v; notifyListeners(); }

async function cloneServer(sourceId: string, targetId: string, options: CloneOptions, log: (e: LogEntry) => void, setProgress: (p: number) => void) {
    _cancelled = false;
    if (!UserStore.getCurrentUser()) { log({ text: "Discord user was not found. Restart Discord, then try again.", type: "err" }); return; }
    const steps = [options.guildSettings && "settings", options.icon && "icon", options.roles && "roles", options.channels && "channels", options.emojis && "emojis"].filter(Boolean) as string[];
    let currentStep = 0;
    const advance = (name: string) => { currentStep++; setProgress(Math.round((currentStep / steps.length) * 100)); log({ text: `-- ${name} done (${currentStep}/${steps.length})`, type: "info" }); };
    const isCancelled = () => { if (_cancelled) { log({ text: "Cancelled.", type: "warn" }); return true; } return false; };
    const sourceGuild = GuildStore.getGuild(sourceId); if (!sourceGuild) { log({ text: "Source server not found", type: "err" }); return; }
    log({ text: `Cloning "${sourceGuild.name}"...`, type: "info" });
    if (options.guildSettings && !isCancelled()) { try { const patch: any = {}; if (sourceGuild.name) patch.name = sourceGuild.name; if (sourceGuild.description) patch.description = sourceGuild.description; if (Object.keys(patch).length) { await apiCall("patch", `/guilds/${targetId}`, patch); log({ text: "Settings copied", type: "ok" }); } } catch (e: any) { log({ text: `Settings error: ${e?.message}`, type: "err" }); } await wait(500); advance("Settings"); }
    if (options.icon && sourceGuild.icon && !isCancelled()) { try { const iconUrl = IconUtils?.getGuildIconURL({ id: sourceId, icon: sourceGuild.icon, size: 512 }) ?? ""; if (iconUrl) { const blob = await (await fetch(iconUrl)).blob(); const base64 = await new Promise<string>(res => { const r = new FileReader(); r.onloadend = () => res(r.result as string); r.readAsDataURL(blob); }); await apiCall("patch", `/guilds/${targetId}`, { icon: base64 }); log({ text: "Icon copied", type: "ok" }); } } catch (e: any) { log({ text: `Icon error: ${e?.message}`, type: "err" }); } await wait(500); advance("Icon"); } else if (options.icon) advance("Icon");
    const roleMapping = new Map<string, string>();
    if (options.roles && !isCancelled()) { try { const sourceRoles: any[] = await apiCall("get", `/guilds/${sourceId}/roles`); const targetRoles: any[] = await apiCall("get", `/guilds/${targetId}/roles`); if (options.clearRoles) { for (const r of targetRoles) { if (r.name === "@everyone" || r.managed) continue; try { await apiCall("del", `/guilds/${targetId}/roles/${r.id}`); await wait(300); } catch { } } } const evSrc = sourceRoles.find(r => r.name === "@everyone"); const updatedTarget: any[] = await apiCall("get", `/guilds/${targetId}/roles`); const evTgt = updatedTarget.find(r => r.name === "@everyone"); if (evSrc && evTgt) roleMapping.set(evSrc.id, evTgt.id); for (const role of sourceRoles.filter(r => r.name !== "@everyone").sort((a, b) => b.position - a.position)) { try { const body: any = { name: role.name, color: role.color, hoist: role.hoist, mentionable: role.mentionable }; if (options.permissions && role.permissions != null) body.permissions = String(role.permissions); const created = await apiCall("post", `/guilds/${targetId}/roles`, body); roleMapping.set(role.id, created.id); log({ text: `  Role: ${role.name}`, type: "ok" }); await wait(300); } catch (e: any) { log({ text: `  Role error "${role.name}": ${e?.message}`, type: "err" }); } } } catch (e: any) { log({ text: `Roles error: ${e?.message}`, type: "err" }); } await wait(500); advance("Roles"); }
    const channelMapping = new Map<string, string>();
    if (options.channels && !isCancelled()) { try { const sourceChannels: any[] = await apiCall("get", `/guilds/${sourceId}/channels`); if (!options.noDeleteChannels) { const tgt: any[] = await apiCall("get", `/guilds/${targetId}/channels`); for (const ch of tgt) { try { await apiCall("del", `/channels/${ch.id}`); await wait(300); } catch { } } } for (const cat of sourceChannels.filter(c => c.type === 4).sort((a, b) => a.position - b.position)) { if (_cancelled) break; try { const body: any = { name: cat.name, type: 4, position: cat.position }; if (options.permissions && cat.permission_overwrites?.length) body.permission_overwrites = mapPermOverwrites(cat.permission_overwrites, roleMapping); const created = await apiCall("post", `/guilds/${targetId}/channels`, body); channelMapping.set(cat.id, created.id); log({ text: `  Category: ${cat.name}`, type: "ok" }); await wait(500); } catch (e: any) { log({ text: `  Category error: ${e?.message}`, type: "err" }); } } for (const ch of sourceChannels.filter(c => c.type !== 4).sort((a, b) => a.position - b.position)) { if (_cancelled) break; try { const body: any = { name: ch.name, type: ch.type, position: ch.position, topic: ch.topic, nsfw: ch.nsfw ?? false, bitrate: ch.bitrate, user_limit: ch.user_limit, rate_limit_per_user: ch.rate_limit_per_user }; if (ch.parent_id && channelMapping.has(ch.parent_id)) body.parent_id = channelMapping.get(ch.parent_id); if (options.permissions && ch.permission_overwrites?.length) body.permission_overwrites = mapPermOverwrites(ch.permission_overwrites, roleMapping); const created = await apiCall("post", `/guilds/${targetId}/channels`, body); channelMapping.set(ch.id, created.id); log({ text: `  Channel: #${ch.name}`, type: "ok" }); await wait(500); } catch (e: any) { log({ text: `  Channel error: ${e?.message}`, type: "err" }); } } } catch (e: any) { log({ text: `Channels error: ${e?.message}`, type: "err" }); } await wait(500); advance("Channels"); }
    if (options.emojis && !isCancelled()) { try { const sourceEmojis: any[] = await apiCall("get", `/guilds/${sourceId}/emojis`); let count = 0; for (const emoji of sourceEmojis) { if (_cancelled) break; try { const emojiUrl = IconUtils?.getEmojiURL({ id: emoji.id, animated: emoji.animated, size: 128 }) ?? ""; if (!emojiUrl) continue; const blob = await (await fetch(emojiUrl)).blob(); const base64 = await new Promise<string>(res => { const r = new FileReader(); r.onloadend = () => res(r.result as string); r.readAsDataURL(blob); }); await apiCall("post", `/guilds/${targetId}/emojis`, { name: emoji.name, image: base64, roles: [] }); count++; log({ text: `  Emoji: ${emoji.name} (${count}/${sourceEmojis.length})`, type: "ok" }); await wait(3000); } catch (e: any) { log({ text: `  Emoji error: ${e?.message}`, type: "err" }); } } } catch (e: any) { log({ text: `Emojis error: ${e?.message}`, type: "err" }); } advance("Emojis"); }
    setProgress(100);
    if (_cancelled) { Toasts.show({ message: "Cloning cancelled.", type: Toasts.Type.FAILURE, id: Toasts.genId() }); }
    else { log({ text: "Done.", type: "info" }); Toasts.show({ message: "Server cloning finished!", type: Toasts.Type.SUCCESS, id: Toasts.genId() }); }
}

function ServerClonerUI({ initialSourceId = "" }: { initialSourceId?: string }) {
    const [sourceId, setSourceId] = useState<string>(initialSourceId); const [targetId, setTargetId] = useState<string>("");
    const [opts, setOpts] = useState<CloneOptions>({ roles: true, clearRoles: true, channels: true, noDeleteChannels: false, permissions: true, icon: true, emojis: true, guildSettings: true });
    const [, forceUpdate] = useState(0); const logRef = useRef<HTMLDivElement>(null);
    React.useEffect(() => { const l = () => forceUpdate(n => n + 1); _listeners.add(l); return () => { _listeners.delete(l); }; }, []);
    React.useEffect(() => { if (logRef.current) logRef.current.scrollTop = logRef.current.scrollHeight; }, [_logs.length]);
    const allGuilds = useMemo(() => Object.values(GuildStore.getGuilds() as Record<string, any>).sort((a, b) => a.name.localeCompare(b.name)).map(g => ({ label: g.name, value: g.id })), []);
    const adminGuilds = useMemo(() => allGuilds.filter(g => hasAdmin(g.value)), [allGuilds]);
    async function startClone() { if (!sourceId || !targetId || _running) return; if (sourceId === targetId) { persistLog({ text: "Source and target cannot be the same!", type: "err" }); return; } persistRunning(true); _progress = 0; _logs = []; notifyListeners(); try { await cloneServer(sourceId, targetId, opts, persistLog, persistProgress); } catch (e: any) { persistLog({ text: `Fatal: ${e?.message}`, type: "err" }); } persistRunning(false); }
    const logColors: Record<string, string> = { ok: "#3ba55d", err: "#ed4245", warn: "#faa81a", info: "#dcddde" };
    const OPTS = [{ key: "guildSettings", label: "Server settings" }, { key: "icon", label: "Icon" }, { key: "roles", label: "Roles" }, { key: "clearRoles", label: "Delete existing roles" }, { key: "channels", label: "Channels" }, { key: "noDeleteChannels", label: "Keep existing channels" }, { key: "permissions", label: "Permissions" }, { key: "emojis", label: "Emojis" }] as const;
    return (
        <div style={{ display: "flex", flexDirection: "column", gap: 16 }}>
            <F.FormSection><F.FormTitle>Source server</F.FormTitle><Select options={allGuilds} placeholder="Choose..." isSelected={v => v === sourceId} select={v => setSourceId(v)} serialize={v => v} /></F.FormSection>
            <F.FormSection><F.FormTitle>Target server (ADMIN required)</F.FormTitle>{adminGuilds.length === 0 ? <F.FormText style={{ color: "var(--text-danger)" }}>No admin servers found.</F.FormText> : <Select options={adminGuilds} placeholder="Choose..." isSelected={v => v === targetId} select={v => setTargetId(v)} serialize={v => v} />}</F.FormSection>
            <F.FormDivider />
            <F.FormSection><F.FormTitle>Options</F.FormTitle><div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: "0 24px" }}>{OPTS.map(o => <FormSwitch key={o.key} title={o.label} value={opts[o.key]} onChange={v => setOpts(p => ({ ...p, [o.key]: v }))} disabled={_running} hideBorder />)}</div></F.FormSection>
            <F.FormDivider />
            <div style={{ display: "flex", gap: 8 }}>
                <Button size={Button.Sizes.MEDIUM} color={_running ? Button.Colors.PRIMARY : Button.Colors.BRAND} disabled={!sourceId || !targetId || _running} onClick={startClone} style={{ flex: 1 }}>{_running ? "Cloning..." : "Start cloning"}</Button>
                {_running && <Button size={Button.Sizes.MEDIUM} color={Button.Colors.RED} onClick={() => { _cancelled = true; }} style={{ minWidth: 100 }}>Stop</Button>}
            </div>
            {_running && <div style={{ height: 8, background: "var(--background-modifier-accent)", borderRadius: 4, overflow: "hidden" }}><div style={{ height: "100%", width: `${_progress}%`, background: "var(--brand-experiment)", transition: "width 0.3s" }} /></div>}
            {_logs.length > 0 && <div ref={logRef} style={{ maxHeight: 200, overflowY: "auto", background: "var(--background-secondary)", borderRadius: 4, padding: 8, fontFamily: "monospace", fontSize: 12 }}>{_logs.map((l, i) => <div key={i} style={{ color: logColors[l.type], marginBottom: 2 }}>{l.text}</div>)}</div>}
        </div>
    );
}

function ServerClonerModal({ rootProps, guildId }: { rootProps: RenderModalProps; guildId: string }) {
    return <Modal {...rootProps} size="lg" title="Server Cloner"><div style={{ paddingBottom: 8 }}><ServerClonerUI initialSourceId={guildId} /></div></Modal>;
}

const patchGuildContext: NavContextMenuPatchCallback = (children, { guild }) => { if (!children || !Array.isArray(children) || !guild) return; try { children.push(<Menu.MenuItem id="server-cloner" key="server-cloner" label="ServerCloner" action={() => openModal(props => <ServerClonerModal rootProps={props} guildId={guild.id} />)} />); } catch { } };
const settings = definePluginSettings({ cloner: { type: OptionType.COMPONENT, description: "", component: ServerClonerUI as any } });

export default definePlugin({
    name: "ServerCloner", enabledByDefault: true,
    description: "Clone an entire server to another server where you have ADMIN. Right-click a server to open.",
    authors: [{ name: "Nightcord", id: 0n }], settings,
    start() { addContextMenuPatch("guild-context", patchGuildContext); },
    stop() { removeContextMenuPatch("guild-context", patchGuildContext); _cancelled = true; _running = false; _listeners.clear(); }
});
