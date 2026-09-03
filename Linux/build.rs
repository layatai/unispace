use std::{
    env, io,
    path::{Path, PathBuf},
    process::{Command, ExitStatus},
};

fn main() {
    println!("cargo:rerun-if-changed=ui/src");
    println!("cargo:rerun-if-changed=ui/index.html");
    println!("cargo:rerun-if-changed=ui/package.json");
    println!("cargo:rerun-if-changed=ui/pnpm-lock.yaml");
    println!("cargo:rerun-if-changed=ui/vite.config.ts");
    println!("cargo:rerun-if-changed=ui/components.json");
    println!("cargo:rerun-if-changed=ui/tsconfig.json");
    if env::var_os("UNISPACE_SKIP_UI_BUILD").is_none() {
        let ui =
            PathBuf::from(env::var("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR")).join("ui");
        if let Err(error) = ensure_ui_dist(&ui) {
            panic!("{error}");
        }
    }
    tauri_build::build();
}

fn ensure_ui_dist(ui: &Path) -> Result<(), String> {
    if !ui.join("package.json").is_file() {
        return Err("Linux/ui/package.json is missing".into());
    }
    if !ui.join("node_modules").is_dir() {
        run_pnpm(ui, &["install", "--frozen-lockfile"])?;
    }
    run_pnpm(ui, &["build"])?;
    if !ui.join("dist/index.html").is_file() {
        return Err("pnpm build did not produce ui/dist/index.html".into());
    }
    Ok(())
}

fn run_pnpm(ui: &Path, args: &[&str]) -> Result<(), String> {
    let status = Command::new("pnpm")
        .args(args)
        .current_dir(ui)
        .status()
        .map_err(|error| {
            if error.kind() == io::ErrorKind::NotFound {
                "pnpm was not found. Install Node LTS and pnpm, then rebuild.".into()
            } else {
                format!("failed to run pnpm: {error}")
            }
        })?;
    if status.success() {
        Ok(())
    } else {
        Err(format!(
            "pnpm {} failed ({})",
            args.join(" "),
            exit_label(status)
        ))
    }
}

fn exit_label(status: ExitStatus) -> String {
    status
        .code()
        .map(|code| format!("exit {code}"))
        .unwrap_or_else(|| "terminated by signal".into())
}
