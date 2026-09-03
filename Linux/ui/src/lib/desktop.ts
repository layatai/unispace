import { invokeCommand } from "@/lib/tauri";

export type DesktopId = "gnome" | "kde";

export interface DesktopInfo {
  id: DesktopId;
  /** The desktop's colour-scheme preference, or null when it has none. */
  dark: boolean | null;
}

const darkQuery = "(prefers-color-scheme: dark)";

function normalize(value: unknown): DesktopInfo | undefined {
  if (!value || typeof value !== "object") return undefined;
  const raw = value as { id?: unknown; dark?: unknown };
  const id = raw.id === "kde" ? "kde" : "gnome";
  const dark = typeof raw.dark === "boolean" ? raw.dark : null;
  return { id, dark };
}

/**
 * Dress the window as the host desktop.
 *
 * The desktop identity is injected before the first paint (see `on_page_load`
 * in src/bin/ui.rs) so the palette is right immediately. `prefers-color-scheme`
 * is the live signal for light/dark, and the desktop's own setting wins when it
 * has one, because WebKitGTK does not always follow a GTK theme change.
 */
export function applyDesktopTheme(info?: DesktopInfo): void {
  const desktop = info ?? normalize(window.__unispaceDesktop) ?? { id: "gnome", dark: null };
  const dark = desktop.dark ?? window.matchMedia(darkQuery).matches;
  const root = document.documentElement;
  root.dataset.desktop = desktop.id;
  root.dataset.theme = dark ? "dark" : "light";
}

export function installDesktopTheme(): void {
  window.__unispaceSyncTheme = () => applyDesktopTheme();
  applyDesktopTheme();

  // A theme change in the desktop's settings should reach the window without a
  // restart: the media query covers WebKitGTK, and re-asking the desktop on
  // focus covers the cases where it does not fire.
  window.matchMedia(darkQuery).addEventListener("change", () => applyDesktopTheme());
  window.addEventListener("focus", () => {
    void refreshDesktopTheme();
  });
  void refreshDesktopTheme();
}

async function refreshDesktopTheme(): Promise<void> {
  try {
    const info = normalize(await invokeCommand<unknown>("desktop"));
    if (!info) return;
    window.__unispaceDesktop = info;
    applyDesktopTheme(info);
  } catch {
    // Not running under Tauri, or the command is unavailable: the injected
    // value and the media query already cover it.
  }
}
