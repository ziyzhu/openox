import app from "./app/contracts.json";
import conversation from "./conversation/contracts.json";
import fs from "./fs/contracts.json";
import provider from "./provider/contracts.json";
import repository from "./repository/contracts.json";
import schedule from "./schedule/contracts.json";
import secret from "./secret/contracts.json";
import service from "./service/contracts.json";
import skill from "./skill/contracts.json";
import user from "./user/contracts.json";
import vision from "./vision/contracts.json";
import web from "./web/contracts.json";

export const contracts = {
  ...app,
  ...conversation,
  ...fs,
  ...provider,
  ...repository,
  ...schedule,
  ...secret,
  ...service,
  ...skill,
  ...user,
  ...vision,
  ...web,
};
