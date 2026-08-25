const ORIGIN = "https://www.chictr.org.cn";
const START_URL = `${ORIGIN}/images/fav.ico`;
const normalizedLabel = (value) => cleanText(value)
    .replace(/[：:]$/, "")
    .toLowerCase();
const englishText = (element) => {
    if (!element)
        return "";
    const copy = element.cloneNode(true);
    copy.querySelectorAll(".cn, script, style").forEach((node) => node.remove());
    return cleanText(copy.textContent).replace(/\u00a0/g, " ").trim();
};
const labelElement = (root, label) => [...root.querySelectorAll("p.en, span.en")]
    .find((element) => normalizedLabel(element.textContent) === normalizedLabel(label));
const fieldCell = (root, label) => {
    const labelCell = labelElement(root, label)?.closest("td");
    if (!labelCell)
        return null;
    if (labelCell.nextElementSibling)
        return labelCell.nextElementSibling;
    const row = labelCell.parentElement;
    const previousRow = row?.previousElementSibling;
    if (!row || !previousRow)
        return null;
    const index = [...row.children].indexOf(labelCell);
    return previousRow.children[index + 1] ?? null;
};
const fieldText = (root, label) => englishText(fieldCell(root, label));
const absoluteUrl = (value) => value ? new URL(value, ORIGIN).href : "";
const optional = (key, value) => value ? { [key]: value } : {};
const tablesInField = (root, label) => {
    const cell = fieldCell(root, label);
    if (!cell)
        return [];
    return [...cell.querySelectorAll(":scope > table, :scope > div > table")];
};
const ageValue = (root, label) => {
    const marker = labelElement(root, label);
    const valueCell = marker?.closest("td")?.nextElementSibling;
    if (!valueCell)
        return "";
    const value = englishText(valueCell);
    if (!value)
        return "";
    const unitCell = valueCell.nextElementSibling;
    return cleanText(`${value} ${englishText(unitCell)}`);
};
window.ox.install(1, ({ action, log, lib }) => {
    const { cleanText, pageCursor } = lib;
    action("searchTrials", {
        async invoke({ query, cursor, }) {
            if (!query)
                throw new Error("searchTrials: query is required");
            const page = pageCursor(cursor, 1);
            const totalElement = document.querySelector("#data-totalEN");
            if (!totalElement) {
                throw new Error("searchTrials: registry search page did not load");
            }
            const rows = [...document.querySelectorAll("table.table1 tr")]
                .filter((row) => row.querySelector("a[href*='showprojEN.html?proj=']"));
            const items = rows.map((row) => {
                const cells = [...row.querySelectorAll(":scope > td")];
                const link = row.querySelector("a[href*='showprojEN.html?proj=']");
                const url = absoluteUrl(link?.getAttribute("href") ?? null);
                return {
                    id: url ? new URL(url).searchParams.get("proj") ?? "" : "",
                    registrationNumber: englishText(cells[1] ?? null),
                    title: englishText(link),
                    institution: englishText(link?.parentElement?.querySelector("p") ?? null),
                    studyType: englishText(cells[3] ?? null),
                    registeredAt: englishText(cells[4] ?? null),
                    url,
                };
            }).filter((item) => item.id && item.registrationNumber && item.title && item.url);
            const totalCount = Number.parseInt(englishText(totalElement), 10) || 0;
            const nextCursor = page * 10 < totalCount ? String(page + 1) : null;
            log(`searchTrials "${query}" page ${page}: ${items.length}/${totalCount}`);
            return { items, totalCount, nextCursor };
        },
    });
    action("getTrial", {
        async invoke({ id }) {
            if (!id)
                throw new Error("getTrial: id is required");
            const url = `${ORIGIN}/showprojEN.html?proj=${encodeURIComponent(id)}`;
            const doc = document;
            const title = englishText(doc.querySelector(".project-tit p.en"));
            const registrationNumber = fieldText(doc, "Registration number");
            if (!title || !registrationNumber)
                throw new Error(`getTrial: no trial found for id ${id}`);
            const interventions = tablesInField(doc, "Interventions")
                .map((table) => {
                const sampleSizeText = fieldText(table, "Sample size");
                const sampleSize = Number.parseInt(sampleSizeText, 10);
                return {
                    group: fieldText(table, "Group"),
                    intervention: fieldText(table, "Intervention"),
                    ...(Number.isFinite(sampleSize) ? { sampleSize } : {}),
                    ...optional("code", fieldText(table, "Intervention code")),
                };
            })
                .filter((item) => item.group || item.intervention);
            const locations = tablesInField(doc, "Countries of recruitment and research settings")
                .map((table) => ({
                country: fieldText(table, "Country"),
                province: fieldText(table, "Province"),
                city: fieldText(table, "City"),
                institution: fieldText(table, "Institution hospital"),
                level: fieldText(table, "Level of the institution"),
            }))
                .filter((item) => item.country || item.institution);
            const outcomes = tablesInField(doc, "Outcomes")
                .map((table) => ({
                name: fieldText(table, "Outcome"),
                type: fieldText(table, "Type"),
                timepoint: fieldText(table, "Measure time point of outcome"),
                method: fieldText(table, "Measure method"),
            }))
                .filter((item) => item.name);
            const result = {
                id,
                registrationNumber,
                title,
                url,
                interventions,
                locations,
                outcomes,
                ...optional("updatedAt", fieldText(doc, "Date of Last Refreshed on")),
                ...optional("registeredAt", fieldText(doc, "Date of Registration")),
                ...optional("registrationStatus", fieldText(doc, "Registration Status")),
                ...optional("scientificTitle", fieldText(doc, "Scientific title")),
                ...optional("acronym", fieldText(doc, "English Acronym")),
                ...optional("subjectId", fieldText(doc, "Study subject ID")),
                ...optional("studyLeader", fieldText(doc, "Study leader")),
                ...optional("institution", fieldText(doc, "Affiliation of the Leader")),
                ...optional("ethicsApproved", fieldText(doc, "Approved by ethic committee")),
                ...optional("ethicsCommittee", fieldText(doc, "Name of the ethic committee")),
                ...optional("primarySponsor", fieldText(doc, "Primary sponsor")),
                ...optional("fundingSource", fieldText(doc, "Source(s) of funding")),
                ...optional("targetDisease", fieldText(doc, "Target disease")),
                ...optional("targetDiseaseCode", fieldText(doc, "Target disease code")),
                ...optional("studyType", fieldText(doc, "Study type")),
                ...optional("phase", fieldText(doc, "Study phase")),
                ...optional("design", fieldText(doc, "Study design")),
                ...optional("objectives", fieldText(doc, "Objectives of Study")),
                ...optional("inclusionCriteria", fieldText(doc, "Inclusion criteria")),
                ...optional("exclusionCriteria", fieldText(doc, "Exclusion criteria")),
                ...optional("studyStart", englishText(doc.querySelector(".splaceTen3"))),
                ...optional("studyEnd", englishText(doc.querySelector(".splaceTen4"))),
                ...optional("recruitmentStart", englishText(doc.querySelector(".splaceTen5"))),
                ...optional("recruitmentEnd", englishText(doc.querySelector(".splaceTen6"))),
                ...optional("recruitingStatus", fieldText(doc, "Recruiting status")),
                ...optional("minimumAge", ageValue(fieldCell(doc, "Participant age") ?? doc, "Min age")),
                ...optional("maximumAge", ageValue(fieldCell(doc, "Participant age") ?? doc, "Max age")),
                ...optional("gender", fieldText(doc, "Gender")),
                ...optional("blinding", fieldText(doc, "Blinding")),
                ...optional("ipdSharing", fieldText(doc, "IPD sharing")),
                ...optional("ipdSharingPlan", fieldText(doc, "The way of sharing IPD”(include metadata and protocol, If use web-based public database, please provide the url)")),
            };
            log(`getTrial ${id}: ${interventions.length} interventions, ${locations.length} locations, ${outcomes.length} outcomes`);
            return result;
        },
    });
});
