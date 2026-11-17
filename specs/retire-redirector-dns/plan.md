# Plan

Scoped from installed official Spec Kit spec/plan/tasks templates.
POSIX shell, Keenetic/Entware; no new dependencies.

1. Observe retirement regression failing against current worker.
2. Replace old writer with exact-host cleanup; preserve legacy entrypoint for
   deployed launchers and success-marker handling for older updaters.
3. Update caller descriptions and error reporting; retain independent flock
   provisioning. No generator/datapath changes or restart steps.
4. Targeted tests, complete suite and update rehearsal.
5. Commit, signed p-88.7, authorized push, CI/publication and public checks.
