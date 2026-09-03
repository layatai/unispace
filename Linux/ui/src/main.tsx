import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { App } from "./app";
import { installDesktopTheme } from "./lib/desktop";
import "./index.css";

installDesktopTheme();

const root = document.getElementById("root");
if (!root) {
  throw new Error("UniSpace root element is missing");
}

createRoot(root).render(
  <StrictMode>
    <App />
  </StrictMode>,
);
