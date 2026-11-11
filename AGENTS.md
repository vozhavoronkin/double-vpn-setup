# AGENTS.md

## Repo status

- Fresh scaffold: branch `main` has no commits yet; there is no source code, README, or build system (no Gradle/Maven/npm). Verify tooling exists before running any build/test command.
- IntelliJ project files (`.idea/`, `double-vpn-setup.iml`) are intentionally staged for the initial commit — do not delete or gitignore them as junk.

## Toolchain signals (from `.idea/`)

- Java project; project type is JPA-oriented (`jpab`) with the Amplicode JPA plugin active — expect JPA entities/Repositories to be the likely core once code exists.
- CheckStyle-IDEA plugin is installed but no custom checkstyle config exists yet (only bundled Sun/Google checks); nothing enforces style until a config is added.
- Compiler output goes to `out/` (IntelliJ default) since no build tool defines an output dir.

## Keep this file current

Once a build system or code is added, replace this section with the real commands (build, single-test, lint order) and architecture notes.
