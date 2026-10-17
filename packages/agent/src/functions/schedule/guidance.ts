export const guidance: Record<string, string> = {
  "ox.schedule.create": "Schedule a frozen snapshot of one resolved skill package after explicit user confirmation: `await ox.schedule.create({ purpose, skill, argument?, frequency, fireAt?, hour?, minute?, weekday?, timeZone? })`. Use `fireAt` for `once`; use `hour` and `minute` for `daily`; add a weekday name for `weekly`. Times are best-effort on iOS.",
  "ox.schedule.list": "List scheduled skill invocations for the active Profile: `await ox.schedule.list({ purpose })`.",
  "ox.schedule.delete": "Delete one scheduled skill after explicit user confirmation: `await ox.schedule.delete({ purpose, id })`.",
  "ox.schedule.enable": "Enable or disable one scheduled skill after explicit user confirmation: `await ox.schedule.enable({ purpose, id, enabled })`.",
  "ox.schedule.run": "Run one scheduled skill snapshot now after explicit user confirmation: `await ox.schedule.run({ purpose, id })`.",
  "namespace.schedule": "Create, inspect, pause, resume, run, and delete scheduled skill invocations.",
};
