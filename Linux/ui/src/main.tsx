import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { App } from "./app";
import "./index.css";

function syncTheme(): void {
  const dark = window.matchMedia("(prefers-color-scheme: dark)").matches;
  document.documentElement.dataset.theme = dark ? "dark" : "light";
}

syncTheme();
window.matchMedia("(prefers-color-scheme: dark)").addEventListener("change", syncTheme);

const root = document.getElementById("root");
if (!root) {
  throw new Error("UniSpace root element is missing");
}

createRoot(root).render(
  <StrictMode>
    <App />
  </StrictMode>,
);
