import type { ActionInstaller } from "../action.ts";

const ORIGIN = "https://clinicaltrials.gov";
const API = `${ORIGIN}/api/v2`;
const SEARCH_FIELDS = [
  "NCTId", "BriefTitle", "Acronym", "OverallStatus", "StatusVerifiedDate",
  "StudyType", "Phase", "EnrollmentCount", "EnrollmentType", "Condition",
  "InterventionType", "InterventionName", "LeadSponsorName", "BriefSummary",
  "Sex", "MinimumAge", "MaximumAge", "HealthyVolunteers", "StartDate",
  "PrimaryCompletionDate", "CompletionDate", "StudyFirstPostDate",
  "LastUpdatePostDate", "HasResults", "LocationFacility", "LocationStatus",
  "LocationCity", "LocationState", "LocationZip", "LocationCountry", "LocationGeoPoint",
].join(",");
const STUDY_FIELDS = [
  "NCTId", "NCTIdAlias", "OrgStudyId", "SecondaryId", "BriefTitle", "OfficialTitle",
  "Acronym", "OverallStatus", "LastKnownStatus", "WhyStopped", "StatusVerifiedDate",
  "StartDate", "PrimaryCompletionDate", "CompletionDate", "StudyFirstPostDate",
  "ResultsFirstPostDate", "LastUpdatePostDate", "LeadSponsorName", "LeadSponsorClass",
  "CollaboratorName", "BriefSummary", "DetailedDescription", "Condition", "Keyword",
  "StudyType", "Phase", "DesignAllocation", "DesignInterventionModel",
  "DesignPrimaryPurpose", "DesignObservationalModel", "DesignTimePerspective",
  "DesignMasking", "EnrollmentCount", "EnrollmentType", "ArmGroupLabel", "ArmGroupType",
  "ArmGroupDescription", "ArmGroupInterventionName", "InterventionType", "InterventionName",
  "InterventionDescription", "InterventionOtherName", "PrimaryOutcomeMeasure",
  "PrimaryOutcomeDescription", "PrimaryOutcomeTimeFrame", "SecondaryOutcomeMeasure",
  "SecondaryOutcomeDescription", "SecondaryOutcomeTimeFrame", "OtherOutcomeMeasure",
  "OtherOutcomeDescription", "OtherOutcomeTimeFrame", "EligibilityCriteria",
  "HealthyVolunteers", "Sex", "GenderBased", "GenderDescription", "MinimumAge",
  "MaximumAge", "StdAge", "StudyPopulation", "SamplingMethod", "CentralContactName",
  "CentralContactRole", "CentralContactPhone", "CentralContactPhoneExt", "CentralContactEMail",
  "LocationFacility", "LocationStatus", "LocationCity", "LocationState", "LocationZip",
  "LocationCountry", "LocationGeoPoint", "LocationContactName", "LocationContactRole",
  "LocationContactPhone", "LocationContactPhoneExt", "LocationContactEMail", "ReferencePMID",
  "ReferenceType", "ReferenceCitation", "SeeAlsoLinkLabel", "SeeAlsoLinkURL", "HasResults",
].join(",");

type Json = Record<string, any>;
type Nearby = { latitude: number; longitude: number; radiusMiles: number };

const list = <T = Json>(value: unknown): T[] => Array.isArray(value) ? value : [];
const text = (value: unknown) => typeof value === "string" && value.trim() ? value.trim() : undefined;
const number = (value: unknown) => typeof value === "number" && Number.isFinite(value) ? value : undefined;
const studyUrl = (id: string) => `${ORIGIN}/study/${encodeURIComponent(id)}`;
const optional = (key: string, value: unknown) => value === undefined ? {} : { [key]: value };

const dateValue = (value: unknown) => text(value) ?? text((value as Json | undefined)?.date);

const distanceMiles = (aLat: number, aLon: number, bLat: number, bLon: number) => {
  const radians = (degrees: number) => degrees * Math.PI / 180;
  const latitude = radians(bLat - aLat);
  const longitude = radians(bLon - aLon);
  const h = Math.sin(latitude / 2) ** 2
    + Math.cos(radians(aLat)) * Math.cos(radians(bLat)) * Math.sin(longitude / 2) ** 2;
  return 3958.7613 * 2 * Math.atan2(Math.sqrt(h), Math.sqrt(1 - h));
};

const contact = (value: Json) => ({
  ...optional("name", text(value?.name)),
  ...optional("role", text(value?.role)),
  ...optional("phone", text(value?.phone)),
  ...optional("phoneExtension", text(value?.phoneExt)),
  ...optional("email", text(value?.email)),
});

const site = (value: Json, nearby?: Nearby): Json => {
  const lat = number(value?.geoPoint?.lat);
  const lon = number(value?.geoPoint?.lon);
  const distance = nearby && lat !== undefined && lon !== undefined
    ? distanceMiles(nearby.latitude, nearby.longitude, lat, lon)
    : undefined;
  return {
    ...optional("facility", text(value?.facility)),
    ...optional("status", text(value?.status)),
    ...optional("city", text(value?.city)),
    ...optional("state", text(value?.state)),
    ...optional("postalCode", text(value?.zip)),
    ...optional("country", text(value?.country)),
    ...optional("latitude", lat),
    ...optional("longitude", lon),
    ...optional("distanceMiles", distance === undefined ? undefined : Math.round(distance * 10) / 10),
    contacts: list(value?.contacts).map(contact),
  };
};

const recruitingRank = (status: unknown) => {
  if (status === "RECRUITING") return 0;
  if (status === "NOT_YET_RECRUITING") return 1;
  if (status === "ACTIVE_NOT_RECRUITING") return 2;
  return 3;
};

const selectSites = (values: Json[], location: string | undefined, nearby: Nearby | undefined, limit: number) => {
  const locationTokens = location?.toLowerCase().split(/\s+/).filter(Boolean) ?? [];
  const mapped = values.map((value) => ({ raw: value, mapped: site(value, nearby) }));
  const matches = mapped.filter(({ raw, mapped }) => {
    if (nearby) return mapped.distanceMiles !== undefined && mapped.distanceMiles <= nearby.radiusMiles;
    if (!locationTokens.length) return true;
    const haystack = [raw?.facility, raw?.city, raw?.state, raw?.zip, raw?.country]
      .filter(Boolean).join(" ").toLowerCase();
    return locationTokens.every((token) => haystack.includes(token));
  });
  const candidates = nearby || locationTokens.length ? matches : mapped;
  candidates.sort((a, b) => {
    const distanceA = a.mapped.distanceMiles ?? Number.POSITIVE_INFINITY;
    const distanceB = b.mapped.distanceMiles ?? Number.POSITIVE_INFINITY;
    if (distanceA !== distanceB) return distanceA - distanceB;
    return recruitingRank(a.raw?.status) - recruitingRank(b.raw?.status);
  });
  return {
    sites: candidates.slice(0, limit).map(({ mapped }) => mapped),
    sitesCount: values.length,
    sitesTruncated: candidates.length > limit,
  };
};

const intervention = (value: Json) => ({
  ...optional("type", text(value?.type)),
  name: text(value?.name) ?? "Unnamed intervention",
  ...optional("description", text(value?.description)),
  otherNames: list<string>(value?.otherNames).filter((item) => typeof item === "string"),
});

const plannedOutcome = (type: string, value: Json) => ({
  type,
  measure: text(value?.measure) ?? "Unspecified outcome",
  ...optional("description", text(value?.description)),
  ...optional("timeFrame", text(value?.timeFrame)),
});

const group = (value: Json) => ({
  id: text(value?.id) ?? "",
  title: text(value?.title) ?? text(value?.label) ?? "Untitled group",
  ...optional("description", text(value?.description)),
});

const groupValue = (value: Json) => ({
  groupId: text(value?.groupId) ?? "",
  ...optional("value", text(value?.value)),
  ...optional("numSubjects", text(value?.numSubjects)),
  ...optional("numEvents", number(value?.numEvents)),
  ...optional("numAffected", number(value?.numAffected)),
  ...optional("numAtRisk", number(value?.numAtRisk)),
});

const flattenMeasurements = (classes: Json[]) => classes.flatMap((classValue) =>
  list(classValue?.categories).flatMap((category) =>
    list(category?.measurements).map((measurement) => ({
      ...optional("classTitle", text(classValue?.title)),
      ...optional("categoryTitle", text(category?.title)),
      groupId: text(measurement?.groupId) ?? "",
      ...optional("value", text(measurement?.value)),
      ...optional("spread", text(measurement?.spread)),
      ...optional("lowerLimit", text(measurement?.lowerLimit)),
      ...optional("upperLimit", text(measurement?.upperLimit)),
    })),
  ),
);

const resultMeasure = (value: Json) => {
  const measurements = flattenMeasurements(list(value?.classes));
  return {
    title: text(value?.title) ?? "Untitled measure",
    ...optional("type", text(value?.type)),
    ...optional("description", text(value?.description)),
    ...optional("populationDescription", text(value?.populationDescription)),
    ...optional("reportingStatus", text(value?.reportingStatus)),
    ...optional("parameter", text(value?.paramType)),
    ...optional("dispersion", text(value?.dispersionType)),
    ...optional("unit", text(value?.unitOfMeasure)),
    ...optional("timeFrame", text(value?.timeFrame)),
    groups: list(value?.groups).map(group),
    measurements: measurements.slice(0, 100),
    measurementsTruncated: measurements.length > 100,
    analyses: list(value?.analyses).slice(0, 25).map((analysis) => ({
      groupIds: list<string>(analysis?.groupIds).filter((item) => typeof item === "string"),
      ...optional("pValue", text(analysis?.pValue)),
      ...optional("method", text(analysis?.statisticalMethod)),
      ...optional("parameter", text(analysis?.paramType)),
      ...optional("parameterValue", text(analysis?.paramValue)),
      ...optional("confidenceIntervalPercent", text(analysis?.ciPctValue)),
      ...optional("lowerLimit", text(analysis?.ciLowerLimit)),
      ...optional("upperLimit", text(analysis?.ciUpperLimit)),
    })),
  };
};

const adverseEvent = (value: Json) => ({
  term: text(value?.term) ?? "Unspecified event",
  ...optional("organSystem", text(value?.organSystem)),
  ...optional("assessmentType", text(value?.assessmentType)),
  ...optional("notes", text(value?.notes)),
  stats: list(value?.stats).map(groupValue),
});

const install: ActionInstaller = ({ action, retryFetch, log }) => {
  const apiJson = async (path: string, params?: URLSearchParams) => {
    const url = `${API}${path}${params ? `?${params}` : ""}`;
    const response = await retryFetch(url, {
      credentials: "omit",
      headers: { Accept: "application/json" },
    });
    const body = await response.text();
    if (!response.ok) throw new Error(`ClinicalTrials.gov HTTP ${response.status}: ${body.slice(0, 300)}`);
    try {
      return JSON.parse(body);
    } catch {
      throw new Error(`ClinicalTrials.gov returned invalid JSON for ${path}`);
    }
  };

  const withVersion = async (request: Promise<Json>) => {
    const [data, version] = await Promise.all([request, apiJson("/version")]);
    return { data, dataTimestamp: text(version?.dataTimestamp) ?? "unknown" };
  };

  action("searchStudies", {
    async invoke({
      query,
      field = "all",
      statuses,
      location,
      nearby,
      phases,
      studyTypes,
      sex,
      age,
      hasResults,
      updatedAfter,
      advancedQuery,
      sort = "relevance",
      cursor,
      limit = 10,
    }: {
      query: string;
      field?: string;
      statuses?: string[];
      location?: string;
      nearby?: Nearby;
      phases?: string[];
      studyTypes?: string[];
      sex?: string;
      age?: number;
      hasResults?: boolean;
      updatedAfter?: string;
      advancedQuery?: string;
      sort?: string;
      cursor?: string;
      limit?: number;
    }) {
      if (!query) throw new Error("searchStudies: query is required");
      const params = new URLSearchParams({
        fields: SEARCH_FIELDS,
        pageSize: String(Math.min(50, Math.max(1, limit))),
      });
      const queryParam: Record<string, string> = {
        all: "query.term",
        condition: "query.cond",
        intervention: "query.intr",
        title: "query.titles",
        outcome: "query.outc",
        sponsor: "query.spons",
        studyId: "query.id",
      };
      params.set(queryParam[field] ?? "query.term", query);
      if (statuses?.length) params.set("filter.overallStatus", statuses.join("|"));
      if (location) params.set("query.locn", location);
      if (nearby) {
        params.set("filter.geo", `distance(${nearby.latitude},${nearby.longitude},${nearby.radiusMiles}mi)`);
      }
      const filters: string[] = [];
      if (phases?.length) filters.push(`AREA[Phase](${phases.join(" OR ")})`);
      if (studyTypes?.length) filters.push(`AREA[StudyType](${studyTypes.join(" OR ")})`);
      if (sex) filters.push(`AREA[Sex](${sex === "ALL" ? "ALL" : `ALL OR ${sex}`})`);
      if (age !== undefined) {
        filters.push(`AREA[MinimumAge]RANGE[MIN, ${age} Years]`);
        filters.push(`AREA[MaximumAge]RANGE[${age} Years, MAX]`);
      }
      if (hasResults === true) filters.push("AREA[ResultsSection] NOT MISSING");
      if (hasResults === false) filters.push("AREA[ResultsSection] MISSING");
      if (updatedAfter) filters.push(`AREA[LastUpdatePostDate]RANGE[${updatedAfter}, MAX]`);
      if (advancedQuery) filters.push(`(${advancedQuery})`);
      if (filters.length) params.set("filter.advanced", filters.join(" AND "));
      const sortValues: Record<string, string> = {
        newestPosted: "StudyFirstPostDate:desc",
        recentlyUpdated: "LastUpdatePostDate:desc",
        startDate: "StartDate:asc",
      };
      if (sortValues[sort]) params.set("sort", sortValues[sort]);
      if (cursor) params.set("pageToken", cursor);
      else params.set("countTotal", "true");

      const { data, dataTimestamp } = await withVersion(apiJson("/studies", params));
      const studies = list(data?.studies);
      const items = studies.map((study) => {
        const protocol = study?.protocolSection ?? {};
        const identification = protocol?.identificationModule ?? {};
        const status = protocol?.statusModule ?? {};
        const design = protocol?.designModule ?? {};
        const eligibility = protocol?.eligibilityModule ?? {};
        const locations = list(protocol?.contactsLocationsModule?.locations);
        const selectedSites = selectSites(locations, location, nearby, 5);
        const id = text(identification?.nctId) ?? "";
        return {
          id,
          title: text(identification?.briefTitle) ?? id,
          ...optional("acronym", text(identification?.acronym)),
          status: text(status?.overallStatus) ?? "UNKNOWN",
          ...optional("statusVerified", dateValue(status?.statusVerifiedDate)),
          ...optional("studyType", text(design?.studyType)),
          phases: list<string>(design?.phases).filter((item) => typeof item === "string"),
          conditions: list<string>(protocol?.conditionsModule?.conditions).filter((item) => typeof item === "string"),
          interventions: list(protocol?.armsInterventionsModule?.interventions).map(intervention),
          ...optional("sponsor", text(protocol?.sponsorCollaboratorsModule?.leadSponsor?.name)),
          ...optional("briefSummary", text(protocol?.descriptionModule?.briefSummary)),
          ...optional("enrollmentCount", number(design?.enrollmentInfo?.count)),
          ...optional("enrollmentType", text(design?.enrollmentInfo?.type)),
          ...optional("sex", text(eligibility?.sex)),
          ...optional("minimumAge", text(eligibility?.minimumAge)),
          ...optional("maximumAge", text(eligibility?.maximumAge)),
          ...optional("healthyVolunteers", typeof eligibility?.healthyVolunteers === "boolean" ? eligibility.healthyVolunteers : undefined),
          ...optional("startDate", dateValue(status?.startDateStruct)),
          ...optional("primaryCompletionDate", dateValue(status?.primaryCompletionDateStruct)),
          ...optional("completionDate", dateValue(status?.completionDateStruct)),
          ...optional("firstPosted", dateValue(status?.studyFirstPostDateStruct)),
          ...optional("lastUpdated", dateValue(status?.lastUpdatePostDateStruct)),
          hasResults: study?.hasResults === true,
          ...selectedSites,
          url: studyUrl(id),
        };
      }).filter((item) => item.id);
      log(`searchStudies field=${field} results=${items.length} total=${data?.totalCount ?? "paged"} next=${Boolean(data?.nextPageToken)}`);
      return {
        items,
        totalCount: number(data?.totalCount) ?? null,
        nextCursor: text(data?.nextPageToken) ?? null,
        dataTimestamp,
      };
    },
  });

  action("getStudy", {
    async invoke({ id, location, nearby, siteLimit = 25 }: {
      id: string;
      location?: string;
      nearby?: Nearby;
      siteLimit?: number;
    }) {
      const params = new URLSearchParams({ fields: STUDY_FIELDS });
      const { data: study, dataTimestamp } = await withVersion(apiJson(`/studies/${encodeURIComponent(id)}`, params));
      const protocol = study?.protocolSection ?? {};
      const identification = protocol?.identificationModule ?? {};
      const status = protocol?.statusModule ?? {};
      const sponsor = protocol?.sponsorCollaboratorsModule ?? {};
      const design = protocol?.designModule ?? {};
      const arms = protocol?.armsInterventionsModule ?? {};
      const outcomes = protocol?.outcomesModule ?? {};
      const eligibility = protocol?.eligibilityModule ?? {};
      const contactsLocations = protocol?.contactsLocationsModule ?? {};
      const references = protocol?.referencesModule ?? {};
      const nctId = text(identification?.nctId) ?? id;
      const selectedSites = selectSites(
        list(contactsLocations?.locations),
        location,
        nearby,
        Math.min(100, Math.max(1, siteLimit)),
      );
      const result = {
        id: nctId,
        title: text(identification?.briefTitle) ?? nctId,
        ...optional("officialTitle", text(identification?.officialTitle)),
        ...optional("acronym", text(identification?.acronym)),
        aliases: list<string>(identification?.nctIdAliases).filter((item) => typeof item === "string"),
        status: text(status?.overallStatus) ?? "UNKNOWN",
        ...optional("lastKnownStatus", text(status?.lastKnownStatus)),
        ...optional("whyStopped", text(status?.whyStopped)),
        ...optional("statusVerified", dateValue(status?.statusVerifiedDate)),
        ...optional("startDate", dateValue(status?.startDateStruct)),
        ...optional("primaryCompletionDate", dateValue(status?.primaryCompletionDateStruct)),
        ...optional("completionDate", dateValue(status?.completionDateStruct)),
        ...optional("firstPosted", dateValue(status?.studyFirstPostDateStruct)),
        ...optional("resultsFirstPosted", dateValue(status?.resultsFirstPostDateStruct)),
        ...optional("lastUpdated", dateValue(status?.lastUpdatePostDateStruct)),
        ...optional("sponsor", text(sponsor?.leadSponsor?.name)),
        ...optional("sponsorClass", text(sponsor?.leadSponsor?.class)),
        collaborators: list(sponsor?.collaborators).map((value) => text(value?.name)).filter(Boolean),
        ...optional("briefSummary", text(protocol?.descriptionModule?.briefSummary)),
        ...optional("detailedDescription", text(protocol?.descriptionModule?.detailedDescription)),
        conditions: list<string>(protocol?.conditionsModule?.conditions).filter((item) => typeof item === "string"),
        keywords: list<string>(protocol?.conditionsModule?.keywords).filter((item) => typeof item === "string"),
        ...optional("studyType", text(design?.studyType)),
        phases: list<string>(design?.phases).filter((item) => typeof item === "string"),
        ...optional("enrollmentCount", number(design?.enrollmentInfo?.count)),
        ...optional("enrollmentType", text(design?.enrollmentInfo?.type)),
        design: {
          ...optional("allocation", text(design?.designInfo?.allocation)),
          ...optional("interventionModel", text(design?.designInfo?.interventionModel)),
          ...optional("primaryPurpose", text(design?.designInfo?.primaryPurpose)),
          ...optional("observationalModel", text(design?.designInfo?.observationalModel)),
          ...optional("timePerspective", text(design?.designInfo?.timePerspective)),
          ...optional("masking", text(design?.designInfo?.maskingInfo?.masking)),
        },
        arms: list(arms?.armGroups).map((value) => ({
          ...group(value),
          ...optional("type", text(value?.type)),
          interventionNames: list<string>(value?.interventionNames).filter((item) => typeof item === "string"),
        })),
        interventions: list(arms?.interventions).map(intervention),
        outcomes: [
          ...list(outcomes?.primaryOutcomes).map((value) => plannedOutcome("PRIMARY", value)),
          ...list(outcomes?.secondaryOutcomes).map((value) => plannedOutcome("SECONDARY", value)),
          ...list(outcomes?.otherOutcomes).map((value) => plannedOutcome("OTHER", value)),
        ],
        eligibility: {
          ...optional("criteria", text(eligibility?.eligibilityCriteria)),
          ...optional("healthyVolunteers", typeof eligibility?.healthyVolunteers === "boolean" ? eligibility.healthyVolunteers : undefined),
          ...optional("sex", text(eligibility?.sex)),
          ...optional("genderBased", typeof eligibility?.genderBased === "boolean" ? eligibility.genderBased : undefined),
          ...optional("genderDescription", text(eligibility?.genderDescription)),
          ...optional("minimumAge", text(eligibility?.minimumAge)),
          ...optional("maximumAge", text(eligibility?.maximumAge)),
          standardAges: list<string>(eligibility?.stdAges).filter((item) => typeof item === "string"),
          ...optional("studyPopulation", text(eligibility?.studyPopulation)),
          ...optional("samplingMethod", text(eligibility?.samplingMethod)),
        },
        centralContacts: list(contactsLocations?.centralContacts).map(contact),
        ...selectedSites,
        references: list(references?.references).map((value) => ({
          ...optional("pmid", text(value?.pmid)),
          ...optional("type", text(value?.type)),
          citation: text(value?.citation) ?? "Unspecified reference",
          ...optional("url", text(value?.pmid) ? `https://pubmed.ncbi.nlm.nih.gov/${value.pmid}/` : undefined),
        })),
        links: list(references?.seeAlsoLinks).map((value) => ({
          label: text(value?.label) ?? "Related information",
          url: text(value?.url) ?? "",
        })).filter((value) => value.url),
        hasResults: study?.hasResults === true,
        sourceUrl: studyUrl(nctId),
        dataTimestamp,
      };
      log(`getStudy id=${nctId} sites=${result.sites.length}/${result.sitesCount} outcomes=${result.outcomes.length} results=${result.hasResults}`);
      return result;
    },
  });

  action("getStudyResults", {
    async invoke({ id, outcomeLimit = 20, eventLimit = 50 }: {
      id: string;
      outcomeLimit?: number;
      eventLimit?: number;
    }) {
      const params = new URLSearchParams({
        fields: "NCTId,BriefTitle,OverallStatus,ResultsFirstPostDate,LastUpdatePostDate,HasResults,ResultsSection",
      });
      const { data: study, dataTimestamp } = await withVersion(apiJson(`/studies/${encodeURIComponent(id)}`, params));
      if (study?.hasResults !== true || !study?.resultsSection) {
        throw new Error(`getStudyResults: ${id} has no posted results`);
      }
      const protocol = study?.protocolSection ?? {};
      const identification = protocol?.identificationModule ?? {};
      const status = protocol?.statusModule ?? {};
      const results = study?.resultsSection ?? {};
      const flow = results?.participantFlowModule;
      const baseline = results?.baselineCharacteristicsModule;
      const outcomes = list(results?.outcomeMeasuresModule?.outcomeMeasures);
      const adverse = results?.adverseEventsModule;
      const seriousEvents = list(adverse?.seriousEvents);
      const otherEvents = list(adverse?.otherEvents);
      const boundedOutcomeLimit = Math.min(50, Math.max(1, outcomeLimit));
      const boundedEventLimit = Math.min(100, Math.max(1, eventLimit));
      const nctId = text(identification?.nctId) ?? id;
      const baselineMeasures = list(baseline?.measures);
      const response = {
        id: nctId,
        title: text(identification?.briefTitle) ?? nctId,
        status: text(status?.overallStatus) ?? "UNKNOWN",
        ...optional("resultsFirstPosted", dateValue(status?.resultsFirstPostDateStruct)),
        ...optional("lastUpdated", dateValue(status?.lastUpdatePostDateStruct)),
        ...optional("participantFlow", flow ? {
          ...optional("recruitmentDetails", text(flow?.recruitmentDetails)),
          ...optional("preAssignmentDetails", text(flow?.preAssignmentDetails)),
          groups: list(flow?.groups).slice(0, 50).map(group),
          periods: list(flow?.periods).slice(0, 25).map((period) => ({
            title: text(period?.title) ?? "Untitled period",
            milestones: list(period?.milestones).slice(0, 50).map((milestone) => ({
              type: text(milestone?.type) ?? "Unspecified milestone",
              ...optional("comment", text(milestone?.comment)),
              values: list(milestone?.achievements).map(groupValue),
            })),
            withdrawals: list(period?.dropWithdraws).slice(0, 50).map((withdrawal) => ({
              type: text(withdrawal?.type) ?? "Unspecified reason",
              ...optional("comment", text(withdrawal?.comment)),
              values: list(withdrawal?.reasons).map(groupValue),
            })),
          })),
        } : undefined),
        ...optional("baseline", baseline ? {
          ...optional("populationDescription", text(baseline?.populationDescription)),
          groups: list(baseline?.groups).slice(0, 50).map(group),
          measures: baselineMeasures.slice(0, boundedOutcomeLimit).map(resultMeasure),
          measuresCount: baselineMeasures.length,
          measuresTruncated: baselineMeasures.length > boundedOutcomeLimit,
        } : undefined),
        outcomes: outcomes.slice(0, boundedOutcomeLimit).map(resultMeasure),
        outcomesCount: outcomes.length,
        outcomesTruncated: outcomes.length > boundedOutcomeLimit,
        ...optional("adverseEvents", adverse ? {
          ...optional("frequencyThreshold", text(adverse?.frequencyThreshold)),
          ...optional("timeFrame", text(adverse?.timeFrame)),
          ...optional("description", text(adverse?.description)),
          groups: list(adverse?.eventGroups).slice(0, 50).map((value) => ({
            ...group(value),
            ...optional("deathsAffected", number(value?.deathsNumAffected)),
            ...optional("deathsAtRisk", number(value?.deathsNumAtRisk)),
            ...optional("seriousAffected", number(value?.seriousNumAffected)),
            ...optional("seriousAtRisk", number(value?.seriousNumAtRisk)),
            ...optional("otherAffected", number(value?.otherNumAffected)),
            ...optional("otherAtRisk", number(value?.otherNumAtRisk)),
          })),
          seriousEvents: seriousEvents.slice(0, boundedEventLimit).map(adverseEvent),
          seriousEventsCount: seriousEvents.length,
          seriousEventsTruncated: seriousEvents.length > boundedEventLimit,
          otherEvents: otherEvents.slice(0, boundedEventLimit).map(adverseEvent),
          otherEventsCount: otherEvents.length,
          otherEventsTruncated: otherEvents.length > boundedEventLimit,
        } : undefined),
        ...optional("limitations", text(results?.moreInfoModule?.limitationsAndCaveats?.description)
          ?? text(results?.moreInfoModule?.limitationsAndCaveats)),
        sourceUrl: `${studyUrl(nctId)}?tab=results`,
        dataTimestamp,
      };
      log(`getStudyResults id=${nctId} outcomes=${response.outcomes.length}/${response.outcomesCount} serious=${seriousEvents.length} other=${otherEvents.length}`);
      return response;
    },
  });
};

export default install;
