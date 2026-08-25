import { cleanText } from "@openox/service-sdk/action-lib";
import type { ActionInstaller } from "@openox/service-sdk/action";

const ORIGIN = "https://www.usvisascheduling.com";
const SCHEDULE_URL = `${ORIGIN}/en-US/schedule/`;
const CUSTOM_ACTIONS_URL = `${ORIGIN}/en-US/custom-actions/`;

const signedOut = () =>
  new Error("USTravelDocs session is signed out. Open the sign-in page, sign in, then retry the check.");

const pageConfiguration = () => {
  const source = [...document.scripts].map((script) => script.textContent ?? "").join("\n");
  const applicationId = source.match(/["']applicationId["']\s*:\s*["']([0-9a-f-]{36})["']/i)?.[1];
  const appd = source.match(/[?&]appd=([0-9a-f-]{36})/i)?.[1];
  return { applicationId, appd };
};

const install: ActionInstaller = ({ action, log }) => {
  const readJson = async (response: Response, label: string) => {
    if (response.status === 401) throw signedOut();
    if (response.status === 403) {
      throw new Error("USTravelDocs rejected this availability check. No retry was attempted.");
    }
    if (response.status === 429) {
      throw new Error("USTravelDocs rate-limited this availability check. No retry was attempted.");
    }
    if (!response.ok) throw new Error(`${label}: HTTP ${response.status}; no retry was attempted`);
    const data = await response.json();
    if (data?.HasError) {
      const message = cleanText(data?.Errors?.m_StringValue) || cleanText(data?.ErrorString);
      throw new Error(message || `${label} failed`);
    }
    return data;
  };

  const postAction = async (route: string, appd: string, parameters: unknown, label: string) => {
    const url = new URL(CUSTOM_ACTIONS_URL);
    url.searchParams.set("route", route);
    url.searchParams.set("appd", appd);
    url.searchParams.set("cacheString", String(Date.now()));
    const response = await fetch(url, {
      method: "POST",
      credentials: "include",
      headers: {
        Accept: "application/json, text/javascript, */*; q=0.01",
        "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8",
        "X-Requested-With": "XMLHttpRequest",
      },
      body: new URLSearchParams({ parameters: JSON.stringify(parameters) }).toString(),
    });
    return readJson(response, label);
  };

  action("getSignInUrl", {
    async invoke() {
      return { url: SCHEDULE_URL };
    },
  });

  action("getSignInState", {
    async invoke() {
      return { signedIn: Boolean(pageConfiguration().applicationId) };
    },
  });

  action("getAppointmentAvailability", {
    async invoke() {
      const { applicationId, appd } = pageConfiguration();
      if (!applicationId || !appd) throw signedOut();

      const [postsResponse, membersResponse] = await Promise.all([
        postAction(
          "/api/v1/schedule-group/query-consular-posts",
          appd,
          { applicationId },
          "Consular post lookup",
        ),
        postAction(
          "/api/v1/schedule-group/query-family-members-consular",
          appd,
          { primaryId: applicationId, visaClass: "all" },
          "Applicant lookup",
        ),
      ]);

      const posts = Array.isArray(postsResponse?.Posts) ? postsResponse.Posts : [];
      const members = Array.isArray(membersResponse?.Members) ? membersResponse.Members : [];
      const post = posts[0];
      if (!post?.ID || !cleanText(post?.Name)) throw new Error("No consular post was found for the current application");
      if (!members.length || members.some((member: any) => !member?.ApplicationID)) {
        throw new Error("No applicants were found for the current application");
      }

      const daysResponse = await postAction(
        "/api/v1/schedule-group/get-family-consular-schedule-days",
        appd,
        {
          primaryId: applicationId,
          applications: members.map((member: any) => String(member.ApplicationID)),
          scheduleDayId: "",
          scheduleEntryId: "",
          postId: String(post.ID),
          isReschedule: "false",
        },
        "Appointment availability",
      );

      const days = Array.isArray(daysResponse?.ScheduleDays) ? daysResponse.ScheduleDays : [];
      const dates = [...new Set(days.map((day: any) => String(day?.Date ?? "").trim()).filter(Boolean))];
      const visaClasses = [...new Set(members.map((member: any) => cleanText(member?.VisaClassName)).filter(Boolean))];
      log(`USTravelDocs availability: posts=${posts.length} applicants=${members.length} dates=${dates.length} requests=3 retries=0`);
      return {
        post: cleanText(post.Name),
        applicantCount: members.length,
        visaClasses,
        available: dates.length > 0,
        dates,
      };
    },
  });
};

export default install;
