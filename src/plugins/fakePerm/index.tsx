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
import definePlugin, { OptionType } from "@utils/types";
import type { RenderModalProps } from "@vencord/discord-types";
import { FluxDispatcher, GuildMemberStore, GuildRoleStore, GuildStore, Menu, Modal, openModal, React, SelectedGuildStore, showToast } from "@webpack/common";

const settings = definePluginSettings({
    enabled: {
        type: OptionType.BOOLEAN,
        description: "Enable fake moderation options in right-click menu",
        default: false,
        onChange(v: boolean) {
            if (!v) {
                document.querySelectorAll("[data-fp-hidden='true']").forEach(el => {
                    (el as HTMLElement).style.display = "";
                    (el as HTMLElement).removeAttribute("data-fp-hidden");
                });
                clearFakePermState();
            }
            showToast(v ? "FakePerm enabled" : "FakePerm disabled");
        }
    }
});

function isEnabled() { return settings.store.enabled; }
function fpHide(el: HTMLElement) { el.style.display = "none"; el.setAttribute("data-fp-hidden", "true"); }
const mutedUsers = new Map<string, boolean>(); const deafenedUsers = new Map<string, boolean>(); const fakeNicks = new Map<string, string>();
const disconnectedUsers = new Set<string>(); const kickedUsers = new Set<string>(); const bannedUsers = new Set<string>(); const deletedMessages = new Set<string>();
const timeoutTimers = new Set<ReturnType<typeof setTimeout>>();
function clearFakePermState() { mutedUsers.clear(); deafenedUsers.clear(); fakeNicks.clear(); disconnectedUsers.clear(); kickedUsers.clear(); bannedUsers.clear(); deletedMessages.clear(); timeoutTimers.forEach(timer => clearTimeout(timer)); timeoutTimers.clear(); }
function getCurrentGuildId(): string | null { try { return SelectedGuildStore?.getGuildId() ?? null; } catch { return null; } }
function notifyMemberListChange() { if (!isEnabled()) return; try { const guildId = getCurrentGuildId(); if (!guildId) return; FluxDispatcher?.dispatch({ type: "GUILD_MEMBER_LIST_UPDATE", ops: [], id: "everyone", guildId }); } catch {} }
function getMember(guildId: string | null, userId: string) { if (!guildId) return null; try { return GuildMemberStore?.getMember(guildId, userId) ?? null; } catch { return null; } }
function getGuildRoles(guildId: string | null): Array<{ id: string; name: string; color: number; }> {
    if (!guildId) return [];
    try { return (GuildRoleStore as any)?.getSortedRoles?.(guildId)?.filter((r: any) => r.id !== guildId).map((r: any) => ({ id: r.id, name: r.name, color: r.color })) ?? []; }
    catch { try { const g = (GuildStore as any)?.getGuild?.(guildId); if (!g?.roles) return []; return Object.values(g.roles as Record<string, any>).filter((r: any) => r.id !== guildId).sort((a: any, b: any) => b.position - a.position).map((r: any) => ({ id: r.id, name: r.name, color: r.color })); } catch { return []; } }
}
function getMemberRoleIds(guildId: string | null, userId: string): string[] { if (!guildId) return []; try { return (GuildMemberStore as any)?.getMember?.(guildId, userId)?.roles ?? []; } catch { return getMember(guildId, userId)?.roles ?? []; } }
function toast(msg: string) { try { showToast(msg); } catch {} }

function hideMessageInDOM(messageId: string) {
    let msgEl: HTMLElement | null = document.querySelector(`[id$="-${messageId}"]`) ?? document.querySelector(`[data-list-item-id$="${messageId}"]`);
    if (!msgEl) { for (const li of document.querySelectorAll("ol[data-list-id='chat-messages'] > li")) { if ((li as HTMLElement).id.includes(messageId)) { msgEl = li as HTMLElement; break; } } }
    if (!msgEl) return; fpHide(msgEl);
}

function RenameModal({ rootProps, user, guildId }: { rootProps: RenderModalProps; user: any; guildId: string | null; }) {
    const [nick, setNick] = React.useState<string>(fakeNicks.get(user.id) ?? getMember(guildId, user.id)?.nick ?? user.username ?? "");
    function applyNick() { const t = nick.trim(); if (t) fakeNicks.set(user.id, t); else fakeNicks.delete(user.id); notifyMemberListChange(); toast("Nickname changed"); rootProps.onClose(); }
    return <Modal {...rootProps} size="sm" title="Change Nickname" actions={[{ text: "Cancel", variant: "secondary", onClick: rootProps.onClose }, { text: "Apply", variant: "primary", onClick: applyNick }]}><input value={nick} onChange={e => setNick(e.target.value)} autoFocus maxLength={32} onKeyDown={e => { if (e.key === "Enter") applyNick(); }} style={{ width: "100%", background: "#383a40", border: "1px solid rgba(255,255,255,0.15)", borderRadius: "8px", padding: "10px 12px", color: "#fff", fontSize: "16px", outline: "none", boxSizing: "border-box" as any }} /></Modal>;
}

function KickModal({ rootProps, user, guildId }: { rootProps: RenderModalProps; user: any; guildId: string | null; }) {
    const [reason, setReason] = React.useState(""); const tag = user.username ?? "";
    function kick() { kickedUsers.add(user.id); disconnectedUsers.add(user.id); notifyMemberListChange(); toast(`@${tag} kicked (local)`); rootProps.onClose(); }
    return <Modal {...rootProps} size="sm" title={`Kick ${user.globalName ?? user.username}`} actions={[{ text: "Cancel", variant: "secondary", onClick: rootProps.onClose }, { text: "Kick", variant: "critical-primary", onClick: kick }]}><textarea value={reason} onChange={e => setReason(e.target.value)} placeholder="Reason" style={{ width: "100%", height: "80px", background: "#1e1f22", border: "1px solid #1e1f22", borderRadius: "4px", padding: "10px", color: "#fff", fontSize: "14px", resize: "none", outline: "none", boxSizing: "border-box" as any }} /></Modal>;
}

function BanModal({ rootProps, user }: { rootProps: RenderModalProps; user: any; }) {
    const [reason, setReason] = React.useState<string | null>(null);
    const REASONS = [{ label: "Suspicious/spam", value: "spam" }, { label: "Compromised", value: "comp" }, { label: "Rule violation", value: "rules" }, { label: "Other", value: "other" }];
    function ban() { if (!reason) return toast("Select a reason"); bannedUsers.add(user.id); kickedUsers.add(user.id); disconnectedUsers.add(user.id); notifyMemberListChange(); toast(`@${user.username} banned (local)`); rootProps.onClose(); }
    return <Modal {...rootProps} size="sm" title={`Ban @${user.username}?`} actions={[{ text: "Cancel", variant: "secondary", onClick: rootProps.onClose }, { text: "Ban", variant: "critical-primary", onClick: ban }]}>{REASONS.map(opt => <label key={opt.value} style={{ display: "flex", alignItems: "center", gap: "12px", cursor: "pointer", fontSize: "16px", color: "#fff", userSelect: "none" as any, marginBottom: 12 }} onClick={() => setReason(opt.value)}><div style={{ width: 20, height: 20, borderRadius: "50%", flexShrink: 0, border: reason === opt.value ? "6px solid #5865f2" : "2px solid #4e5058", background: reason === opt.value ? "#fff" : "transparent", boxSizing: "border-box" as any }} />{opt.label}</label>)}</Modal>;
}

const TDs = [{ label: "60s", seconds: 60 }, { label: "5m", seconds: 300 }, { label: "10m", seconds: 600 }, { label: "1h", seconds: 3600 }, { label: "1d", seconds: 86400 }, { label: "1w", seconds: 604800 }];
function TimeoutModal({ rootProps, user }: { rootProps: RenderModalProps; user: any; }) {
    const [idx, setIdx] = React.useState(0); const tag = user.username ?? "";
    function timeout() { const d = TDs[idx]; disconnectedUsers.add(user.id); notifyMemberListChange(); toast(`@${tag} timed out for ${d.label} (local)`); const timer = setTimeout(() => { timeoutTimers.delete(timer); disconnectedUsers.delete(user.id); notifyMemberListChange(); }, d.seconds * 1000); timeoutTimers.add(timer); rootProps.onClose(); }
    return <Modal {...rootProps} size="sm" title={`Timeout ${user.globalName ?? user.username}`} actions={[{ text: "Cancel", variant: "secondary", onClick: rootProps.onClose }, { text: "Timeout", variant: "primary", onClick: timeout }]}><div style={{ display: "flex", marginBottom: "8px", borderRadius: "4px", overflow: "hidden", border: "1px solid rgba(255,255,255,0.1)" }}>{TDs.map((d, i) => <button key={i} onClick={() => setIdx(i)} style={{ flex: 1, background: idx === i ? "#5865f2" : "#2b2d31", color: "#fff", border: "none", borderRight: i < TDs.length - 1 ? "1px solid rgba(255,255,255,0.1)" : "none", padding: "8px 2px", cursor: "pointer" }}>{d.label}</button>)}</div></Modal>;
}

function findGroupIdx(children: any[], ids: string[]): number { for (let i = 0; i < children.length; i++) { const sub = Array.isArray(children[i]?.props?.children) ? children[i].props.children : children[i]?.props?.children ? [children[i].props.children] : []; if (sub.some((c: any) => c?.props?.id && ids.includes(c.props.id))) return i; } return -1; }

const messageContextPatch: NavContextMenuPatchCallback = (children, { message }: any) => {
    if (!children || !Array.isArray(children) || !isEnabled() || !message?.id || !getCurrentGuildId()) return;
    try { children.splice(-1, 0, (<Menu.MenuGroup key="fp-msg-group"><Menu.MenuItem key="fp-delete-msg" id="fp-delete-msg" label="Delete for me (fake)" color="danger" action={() => { deletedMessages.add(message.id); hideMessageInDOM(message.id); toast("Message deleted (local only)"); }} /></Menu.MenuGroup>)); } catch {}
};

const userContextPatch: NavContextMenuPatchCallback = (children, { user }: any) => {
    if (!children || !Array.isArray(children) || !isEnabled() || !user) return;
    try {
        const guildId = getCurrentGuildId(); if (!guildId) return;
        const allRoles = getGuildRoles(guildId); const memberRoleIds = getMemberRoleIds(guildId, user.id); const { username } = user;
        const groupA = (<Menu.MenuGroup key="fp-group-a">
            <Menu.MenuItem key="fp-rename" id="fp-rename" label="Change Nickname" action={() => openModal(p => <RenameModal rootProps={p} user={user} guildId={guildId} />)} />
            <Menu.MenuItem key="fp-roles" id="fp-roles" label="Roles">
                {allRoles.length === 0 ? <Menu.MenuItem key="fp-roles-empty" id="fp-roles-empty" label="No roles" disabled /> :
                    allRoles.map(role => { const hasRole = memberRoleIds.includes(role.id); const color = role.color ? `#${role.color.toString(16).padStart(6, "0")}` : "#80848e"; return <Menu.MenuItem key={`fp-role-${role.id}`} id={`fp-role-${role.id}`} label={role.name} action={() => {}} render={() => <div style={{ display: "flex", alignItems: "center", padding: "8px 10px", gap: 8, width: "100%", boxSizing: "border-box", cursor: "pointer" }}><div style={{ width: 14, height: 14, borderRadius: "50%", background: color, flexShrink: 0 }} /><span style={{ flex: 1, color: "#fff", fontSize: 14 }}>{role.name}</span><div style={{ width: 16, height: 16, borderRadius: 3, flexShrink: 0, border: hasRole ? "none" : "1.5px solid #72767d", background: hasRole ? "#5865f2" : "transparent", display: "flex", alignItems: "center", justifyContent: "center" }}>{hasRole && <svg width="10" height="8" viewBox="0 0 10 8" fill="none"><path d="M1 4L3.5 6.5L9 1" stroke="white" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" /></svg>}</div></div>} />; })}
            </Menu.MenuItem>
            <Menu.MenuCheckboxItem key="fp-mute" id="fp-mute" label="Server Mute" color="danger" checked={mutedUsers.get(user.id) === true} action={() => { mutedUsers.set(user.id, !mutedUsers.get(user.id)); }} />
            <Menu.MenuCheckboxItem key="fp-deafen" id="fp-deafen" label="Server Deafen" color="danger" checked={deafenedUsers.get(user.id) === true} action={() => { deafenedUsers.set(user.id, !deafenedUsers.get(user.id)); }} />
            <Menu.MenuItem key="fp-disconnect" id="fp-disconnect" label="Disconnect" color="danger" action={() => { disconnectedUsers.add(user.id); notifyMemberListChange(); toast(`@${username} disconnected (local)`); }} />
            <Menu.MenuItem key="fp-timeout" id="fp-timeout" label={`Timeout ${username}`} color="danger" action={() => openModal(p => <TimeoutModal rootProps={p} user={user} />)} />
            <Menu.MenuItem key="fp-kick" id="fp-kick" label={`Kick ${username}`} color="danger" action={() => openModal(p => <KickModal rootProps={p} user={user} guildId={guildId} />)} />
            <Menu.MenuItem key="fp-ban" id="fp-ban" label={`Ban ${username}`} color="danger" action={() => openModal(p => <BanModal rootProps={p} user={user} />)} />
        </Menu.MenuGroup>);
        const idx = findGroupIdx(children, ["block", "ignore"]);
        if (idx >= 0) children.splice(idx + 1, 0, groupA); else children.splice(-1, 0, groupA);
    } catch (e) { console.error("[FakePerm]", e); }
};

export default definePlugin({
    name: "FakePerm", enabledByDefault: false, settings,
    description: "Visually simulates moderation options in right-click menus. No real actions. Enable in plugin settings.",
    authors: [{ name: "Nightcord", id: 0n }], dependencies: ["ContextMenuAPI"],
    patches: [
        { find: "showCommunicationDisabledStyles", predicate: () => isEnabled(), replacement: { match: /&&\i\.\i\.canManageUser\(\i\.\i\.MODERATE_MEMBERS,\i\.author,\i\)/, replace: "" } },
        { find: "INVITES_DISABLED)||", predicate: () => isEnabled(), replacement: { match: /\i\.\i\.can\(\i\.\i.MANAGE_GUILD,\i\)/, replace: "true" } },
        { find: /,checkElevated:!1}\),\i\.\i\)}(?<=getCurrentUser\(\);return.+?)/, predicate: () => isEnabled(), replacement: { match: /return \i\.\i\(\i\.\i\(\{user:\i,context:\i,checkElevated:!1\}\),\i\.\i\)/, replace: "return true" } },
        { find: 'action:"PRESS_MOD_VIEW",icon:', predicate: () => isEnabled(), replacement: { match: /\i(?=\?null)/, replace: "false" } }
    ],
    start() { addContextMenuPatch("message", messageContextPatch); addContextMenuPatch("user-context", userContextPatch); addContextMenuPatch("guild-channel-user-context", userContextPatch); },
    stop() {
        removeContextMenuPatch("message", messageContextPatch); removeContextMenuPatch("user-context", userContextPatch); removeContextMenuPatch("guild-channel-user-context", userContextPatch);
        document.querySelectorAll("[data-fp-hidden='true']").forEach(el => { (el as HTMLElement).style.display = ""; (el as HTMLElement).removeAttribute("data-fp-hidden"); });
        clearFakePermState();
    }
});
