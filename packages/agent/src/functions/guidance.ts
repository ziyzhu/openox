import { guidance as app } from "./app/guidance";
import { guidance as conversation } from "./conversation/guidance";
import { guidance as fs } from "./fs/guidance";
import { guidance as provider } from "./provider/guidance";
import { guidance as repository } from "./repository/guidance";
import { guidance as schedule } from "./schedule/guidance";
import { guidance as secret } from "./secret/guidance";
import { guidance as service } from "./service/guidance";
import { guidance as skill } from "./skill/guidance";
import { guidance as user } from "./user/guidance";
import { guidance as vision } from "./vision/guidance";
import { guidance as web } from "./web/guidance";

export const functionGuidance: Record<string, string> = {
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
