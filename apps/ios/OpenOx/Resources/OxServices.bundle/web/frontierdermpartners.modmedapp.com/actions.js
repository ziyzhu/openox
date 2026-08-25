const ORIGIN = "https://frontierdermpartners.modmedapp.com";
const PORTAL = "/patient-portal";
const HEADER_SELECTOR = "ageInMonths,ageInYears,dateOfBirth,email,encryptedId,fullName,fullNameComplete,gender,inactive,loginEnabled,mrn,pmsId,pqrsId,sex,thumbnailUrl,preferredPhone,nameLastFirst,username,portalEnabled,mustResetPassword,passwordAge,passwordExpired,patientAdditionalInfo(emailOptIn),userPasswordResetRequired,passwordDate,userGraceLoginLeft,hideEmaPasswordServices,timeZone";
const PROFILE_SELECTOR = "id,allowLeaveMessage,caretakerFullName,caretakerPhoneNumber,cellPhone(fullPhoneNumberFormatted),city,country,county,dateOfBirth,dateOfDeath,deceased,differences,driversLicenseNumber,driversLicenseState,email,emailAlt,emergencyContactFullName,emergencyContactPhoneNumber,employerName,endDate,ethnicGroup,ethnicGroupDetails,firstName,homePhone(fullPhoneNumberFormatted),industry(id,name,value,code),languagePrefStandardized,languagePreference,lastName,maritalStatus,middleName,nickName,occupation(id,name,value,code),patientAdditionalInfoDto(emailOptIn),patientGenderDemographics(genderIdentity,genderIdentityOtherText,sexualOrientation,patientPreferredPronoun,id,sexualOrientationOtherText),seasonalAddress(street1,street2,city,state,country,zipcode,startDate,endDate),phoneNumberReadonly,placeOfBirthCity,placeOfBirthCountry,placeOfBirthState,placeOfBirthZipcode,preferredContactMethod,preferredPhoneType,prefix,previousAddress,previousName,races,sex,socialSecurityNumber,spouseFullName,spousePhoneNumber,startDate,state,status,street1,street2,suffix,welcomeText,workPhone(fullPhoneNumberFormatted),hasPmsId,patientPortalDemographicUpdatesForMaverickEnabled,zipcode";
const MEDICATION_SELECTOR = "id,status,dermHistory(id,shOccupation,otherMedications,medicationNone),firmUserCurrentMedications(drugName,id,dateEnded,dateStarted,medicationStatus,dose,doseForm,frequency,genericName,indication,units,strength,drugNameID,route,rx,duringVisit,deletableByPatient,pendingDeletion,location,locationSpecific,routeLocationList)";
const PHARMACY_SELECTOR = "id,erxEnabled,name,phoneNumber,faxNumber,address(city,country,fullStreetAddress,street1,street2,street3,zipcode,state),makeDefault";
const INSURANCE_SELECTOR = "groupNumber,insurancePhoneNumber,guarantorFirstName,guarantorLastName,guarantorHomePhoneNumber,guarantorWorkPhoneNumber";
const ALLERGY_SELECTOR = "id,status,currentAllergies(id,displayName,allergenTypeAsString,deletableByPatient,otherResponse,severity,dateRecorded,fdbAllergenId,status,fdbAllergenTypeId,fdbAllergenIdType,fdbAllergenDesc,description,allergyResponseOtherValue,pendingDeletion,responses,responseValues,dateStarted,dateRecorded,dateEnded,otherResponse),dermHistory(pedBirthLbs,pedBirthOz,otherAllergies,allergyNkda)";
const BALANCE_SELECTOR = "patientBalanceInfoBeanList(unallocatedAmount,outstandingBalance,taxpayerIdentificationNumber,facility(additionalInfo(locationDisplayName),address(fullStreetAddress)))";
const string = (value) => value == null ? "" : String(value);
const optionalString = (value) => value == null || value === "" ? null : String(value);
const optionalNumber = (value) => {
    const number = Number(value);
    return value == null || !Number.isFinite(number) ? null : number;
};
window.ox.install(1, ({ action, retryFetch, log }) => {
    let navigationTail = Promise.resolve();
    const withNavigation = async (work) => {
        const previous = navigationTail;
        let release = () => { };
        navigationTail = new Promise((resolve) => {
            release = resolve;
        });
        await previous.catch(() => { });
        try {
            return await work();
        }
        finally {
            release();
        }
    };
    const requestJson = async (url) => {
        const response = await retryFetch(url, {
            credentials: "include",
            headers: { Accept: "application/json" },
        });
        const text = await response.text();
        if (response.status === 401 || response.status === 403) {
            throw new Error(`ModMed sign-in required (HTTP ${response.status})`);
        }
        if (!response.ok)
            throw new Error(`ModMed HTTP ${response.status}`);
        try {
            return text ? JSON.parse(text) : null;
        }
        catch {
            throw new Error("ModMed returned a non-JSON response");
        }
    };
    const patientHeaderUrl = () => {
        const query = new URLSearchParams({ selector: HEADER_SELECTOR });
        return `${ORIGIN}/ema/ws/v3/patient/header?${query}`;
    };
    const patientId = async () => {
        const header = await requestJson(patientHeaderUrl());
        const id = Number(header?.id);
        if (!Number.isInteger(id) || id <= 0)
            throw new Error("ModMed patient record is unavailable");
        return id;
    };
    const portalReady = () => {
        if (location.hostname !== "frontierdermpartners.modmedapp.com")
            return false;
        if (!location.pathname.startsWith(PORTAL))
            return false;
        return Array.from(document.querySelectorAll("a[href]"))
            .some((candidate) => {
            try {
                return new URL(candidate.href, location.href).pathname.startsWith(`${PORTAL}/`);
            }
            catch {
                return false;
            }
        });
    };
    const waitForPortal = async () => {
        const deadline = Date.now() + 3000;
        while (Date.now() < deadline) {
            if (portalReady())
                return true;
            await new Promise((resolve) => setTimeout(resolve, 100));
        }
        return false;
    };
    const navigateSpa = (path) => {
        const link = Array.from(document.querySelectorAll("a[href]"))
            .find((candidate) => {
            try {
                return new URL(candidate.href, location.href).pathname === path;
            }
            catch {
                return false;
            }
        });
        if (link) {
            link.click();
            return;
        }
        history.pushState({}, "", path);
        dispatchEvent(new PopStateEvent("popstate", { state: history.state }));
    };
    const captureRoute = async (path, pattern, label) => withNavigation(async () => {
        const capture = window.oxFetchCapture;
        if (!capture)
            throw new Error("ModMed response capture is unavailable");
        if (location.pathname === path) {
            const alternate = path.endsWith("/upcoming-visits")
                ? `${PORTAL}/appointments/past-appointments`
                : `${PORTAL}/appointments/upcoming-visits`;
            navigateSpa(alternate);
            await new Promise((resolve) => setTimeout(resolve, 150));
        }
        const pending = capture(pattern, { timeoutMs: 12000, replayLatest: false });
        navigateSpa(path);
        try {
            const body = await pending;
            log(`${label}: captured portal response`);
            return body;
        }
        catch {
            throw new Error(`${label}: the portal did not load the requested data`);
        }
    });
    const inheritedOrFallback = async (path, pattern, label, fallback) => {
        if (portalReady())
            return captureRoute(path, pattern, label);
        try {
            const body = await fallback();
            log(`${label}: used direct response path`);
            return body;
        }
        catch (error) {
            if (await waitForPortal())
                return captureRoute(path, pattern, label);
            throw error;
        }
    };
    action("getSignInUrl", {
        async invoke() {
            return { url: `${ORIGIN}/ema/patient-login` };
        },
    });
    action("getSignInState", {
        async invoke() {
            if (portalReady())
                return { signedIn: true };
            try {
                const header = await requestJson(patientHeaderUrl());
                return { signedIn: Boolean(header?.id && header?.portalEnabled !== false) };
            }
            catch (error) {
                if (/sign-in required \(HTTP (?:401|403)\)/.test(String(error?.message ?? error))) {
                    return { signedIn: await waitForPortal() };
                }
                if (await waitForPortal())
                    return { signedIn: true };
                throw error;
            }
        },
    });
    action("getPatientProfile", {
        async invoke() {
            const body = await inheritedOrFallback(`${PORTAL}/my-health/contact-info`, /\/ema\/ws\/v3\/portal\/patient\/\d+\/info(?:\?|$)/, "getPatientProfile", async () => {
                const id = await patientId();
                const query = new URLSearchParams({ selector: PROFILE_SELECTOR });
                return requestJson(`${ORIGIN}/ema/ws/v3/portal/patient/${id}/info?${query}`);
            });
            return {
                firstName: string(body?.firstName),
                lastName: string(body?.lastName),
                dateOfBirth: optionalString(body?.dateOfBirth),
                sex: optionalString(body?.sex),
                genderIdentity: optionalString(body?.patientGenderDemographics?.genderIdentity),
                sexualOrientation: optionalString(body?.patientGenderDemographics?.sexualOrientation),
                email: optionalString(body?.email),
                phone: optionalString(body?.cellPhone?.fullPhoneNumberFormatted),
                city: optionalString(body?.city),
                state: optionalString(body?.state),
                postalCode: optionalString(body?.zipcode),
                country: optionalString(body?.country),
                preferredContactMethod: optionalString(body?.preferredContactMethod),
                preferredPhoneType: optionalString(body?.preferredPhoneType),
                language: optionalString(body?.languagePrefStandardized ?? body?.languagePreference),
                maritalStatus: optionalString(body?.maritalStatus),
                ethnicity: optionalString(body?.ethnicGroup),
                races: Array.isArray(body?.races) ? body.races.map(string).filter(Boolean) : [],
            };
        },
    });
    action("listPastAppointments", {
        async invoke() {
            const body = await inheritedOrFallback(`${PORTAL}/appointments/past-appointments`, /\/ema\/ws\/v3\/patientPortal\/appointments\/past(?:\?|$)/, "listPastAppointments", async () => {
                const query = new URLSearchParams({
                    where: "",
                    "paging.pageSize": "10",
                    "paging.pageNumber": "1",
                    to: new Date().toLocaleDateString("en-US"),
                    selector: "facility(timeZone,address(fullStreetAddress),mainPhone)",
                    "sorting.sortBy": "visitDate",
                    "sorting.sortOrder": "desc",
                });
                return requestJson(`${ORIGIN}/ema/ws/v3/patientPortal/appointments/past?${query}`);
            });
            const items = (Array.isArray(body) ? body : []).map((visit) => ({
                id: string(visit?.visitEncryptedId ?? visit?.visitId),
                date: string(visit?.visitDate),
                finalized: Boolean(visit?.finalized),
                provider: optionalString(visit?.primaryProvider),
                biller: optionalString(visit?.primaryBiller),
                attendees: optionalString(visit?.attendees),
                additionalAttendees: optionalString(visit?.additionalAttendees),
                impressions: optionalString(visit?.impressions),
                facility: {
                    id: string(visit?.facility?.facilityId ?? visit?.facility?.id),
                    name: string(visit?.facility?.name),
                    address: optionalString(visit?.facility?.address?.fullStreetAddress),
                    phone: optionalString(visit?.facility?.mainPhone?.formattedPhoneNumberWithExtension ?? visit?.facility?.mainPhone?.formattedPhoneNumber),
                    timeZone: optionalString(visit?.facility?.timeZone),
                },
                visitNoteUrl: visit?.visitNotePdfUrl
                    ? new URL(String(visit.visitNotePdfUrl), ORIGIN).toString()
                    : null,
            }));
            return { items, nextCursor: null };
        },
    });
    action("getMedicationHistory", {
        async invoke() {
            const body = await inheritedOrFallback(`${PORTAL}/my-health/medications`, /\/ema\/ws\/v3\/portal\/patient\/\d+\/medicalHistory(?:\?|$)/, "getMedicationHistory", async () => {
                const id = await patientId();
                const query = new URLSearchParams({ selector: MEDICATION_SELECTOR });
                return requestJson(`${ORIGIN}/ema/ws/v3/portal/patient/${id}/medicalHistory?${query}`);
            });
            const items = (Array.isArray(body?.firmUserCurrentMedications) ? body.firmUserCurrentMedications : [])
                .map((medication) => ({
                id: string(medication?.id),
                name: string(medication?.drugName),
                genericName: optionalString(medication?.genericName),
                strength: optionalString(medication?.strength),
                units: optionalString(medication?.units),
                doseForm: optionalString(medication?.doseForm),
                frequency: optionalString(medication?.frequency),
                route: optionalString(medication?.route),
                status: optionalString(medication?.medicationStatus),
                startedAt: optionalString(medication?.dateStarted),
                duringVisit: Boolean(medication?.duringVisit),
                deletableByPatient: Boolean(medication?.deletableByPatient),
            }));
            return { noneReported: Boolean(body?.dermHistory?.medicationNone), items };
        },
    });
    action("listProblems", {
        async invoke() {
            const body = await inheritedOrFallback(`${PORTAL}/my-health/problem-list`, /\/ema\/ws\/v3\/problemListItem(?:\?|$)/, "listProblems", async () => {
                const id = await patientId();
                return requestJson(`${ORIGIN}/ema/ws/v3/problemListItem?paging.pageNumber=1&paging.pageSize=10&sorting.sortBy=dateDiagnosed&sorting.sortOrder=asc&selector=description&where=patient==%22${id}%22`);
            });
            const items = (Array.isArray(body) ? body : []).map((problem) => ({
                id: string(problem?.id),
                description: string(problem?.description),
            }));
            return { items, nextCursor: null };
        },
    });
    action("getAllergySummary", {
        async invoke() {
            const body = await inheritedOrFallback(`${PORTAL}/my-health/allergies`, /\/ema\/ws\/v3\/portal\/patient\/\d+\/allergies(?:\?|$)/, "getAllergySummary", async () => {
                const id = await patientId();
                const query = new URLSearchParams({ selector: ALLERGY_SELECTOR });
                return requestJson(`${ORIGIN}/ema/ws/v3/portal/patient/${id}/allergies?${query}`);
            });
            return {
                noneKnown: Boolean(body?.dermHistory?.allergyNkda),
                otherAllergies: optionalString(body?.dermHistory?.otherAllergies),
                recordedAllergyCount: Array.isArray(body?.currentAllergies) ? body.currentAllergies.length : 0,
            };
        },
    });
    action("getBillingSummary", {
        async invoke() {
            const load = async () => Promise.all([
                requestJson(`${ORIGIN}/ema/ws/v3/patientFinancials/balance/with-configuration?${new URLSearchParams({ selector: BALANCE_SELECTOR })}`),
                requestJson(`${ORIGIN}/ema/ws/v3/patientPortal/account/statements?${new URLSearchParams({
                    where: "",
                    "paging.pageSize": "10",
                    "paging.pageNumber": "1",
                    "sorting.sortBy": "statementDate",
                    "sorting.sortOrder": "desc",
                })}`),
            ]);
            const captureBilling = () => withNavigation(async () => {
                const capture = window.oxFetchCapture;
                if (!capture)
                    throw new Error("ModMed response capture is unavailable");
                if (location.pathname === `${PORTAL}/billing`) {
                    navigateSpa(`${PORTAL}/appointments/upcoming-visits`);
                    await new Promise((resolve) => setTimeout(resolve, 150));
                }
                const pendingBalances = capture(/\/ema\/ws\/v3\/patientFinancials\/balance\/with-configuration(?:\?|$)/, { timeoutMs: 12000 });
                const pendingStatements = capture(/\/ema\/ws\/v3\/patientPortal\/account\/statements(?:\?|$)/, { timeoutMs: 12000 });
                navigateSpa(`${PORTAL}/billing`);
                return Promise.all([pendingBalances, pendingStatements]);
            });
            let balances;
            let statements;
            if (portalReady()) {
                [balances, statements] = await captureBilling();
            }
            else {
                try {
                    [balances, statements] = await load();
                }
                catch (error) {
                    if (!await waitForPortal())
                        throw error;
                    [balances, statements] = await captureBilling();
                }
            }
            const accounts = (Array.isArray(balances) ? balances : []).flatMap((configuration) => (Array.isArray(configuration?.patientBalanceInfoBeanList) ? configuration.patientBalanceInfoBeanList : [])
                .map((balance) => ({
                id: string(balance?.taxpayerIdentificationNumber?.encryptedId ?? balance?.facility?.id),
                facility: string(balance?.facility?.additionalInfo?.locationDisplayName ?? balance?.facility?.name),
                address: optionalString(balance?.facility?.address?.fullStreetAddress),
                billingType: optionalString(balance?.taxpayerIdentificationNumber?.billingType),
                outstandingBalance: optionalNumber(balance?.outstandingBalance),
                unallocatedAmount: optionalNumber(balance?.unallocatedAmount),
                paymentType: optionalString(configuration?.payfacCollectPaymentType),
            })));
            const recentStatements = (Array.isArray(statements) ? statements : []).map((statement) => ({
                id: string(statement?.id ?? statement?.statementNumber),
                statementNumber: optionalString(statement?.statementNumber),
                date: string(statement?.statementDate),
                status: optionalString(statement?.status),
                totalDue: optionalNumber(statement?.totalPatientDue),
                oldestAgingBalance: optionalString(statement?.oldestAgingBalance),
            }));
            return { accounts, recentStatements };
        },
    });
    action("listInsurancePlans", {
        async invoke() {
            const body = await inheritedOrFallback(`${PORTAL}/my-health/insurance-and-pharmacy`, /\/ema\/ws\/v3\/portal\/patient\/\d+\/insurance\/active(?:\?|$)/, "listInsurancePlans", async () => {
                const id = await patientId();
                const query = new URLSearchParams({ selector: INSURANCE_SELECTOR });
                return requestJson(`${ORIGIN}/ema/ws/v3/portal/patient/${id}/insurance/active?${query}`);
            });
            const items = (Array.isArray(body) ? body : []).map((plan) => ({
                id: string(plan?.id),
                company: string(plan?.insuranceCompanyName),
                planType: optionalString(plan?.mavPolicyType),
                active: Boolean(plan?.insuranceActive),
                eligibilityActive: Boolean(plan?.eligibilityActive),
                copayAmount: optionalNumber(plan?.copayAmount),
                referralNeeded: Boolean(plan?.referralNeeded),
                ranking: optionalNumber(plan?.ranking),
                insuredName: optionalString([plan?.patientInsuranceFirstName, plan?.patientInsuranceLastName].filter(Boolean).join(" ")),
                policyholderName: optionalString([plan?.policyHolderFirstName, plan?.policyHolderLastName].filter(Boolean).join(" ")),
            }));
            return { items, nextCursor: null };
        },
    });
    action("listPharmacies", {
        async invoke() {
            const body = await inheritedOrFallback(`${PORTAL}/my-health/insurance-and-pharmacy`, /\/ema\/ws\/v3\/portal\/patient\/\d+\/firm-user-pharmacies(?:\?|$)/, "listPharmacies", async () => {
                const id = await patientId();
                const query = new URLSearchParams({ selector: PHARMACY_SELECTOR });
                return requestJson(`${ORIGIN}/ema/ws/v3/portal/patient/${id}/firm-user-pharmacies?${query}`);
            });
            const items = (Array.isArray(body) ? body : []).map((pharmacy) => ({
                id: string(pharmacy?.id),
                name: string(pharmacy?.name),
                phone: optionalString(pharmacy?.phoneNumber),
                fax: optionalString(pharmacy?.faxNumber),
                address: optionalString(pharmacy?.address?.fullStreetAddress ?? [
                    pharmacy?.address?.street1,
                    pharmacy?.address?.street2,
                    pharmacy?.address?.city,
                    pharmacy?.address?.state,
                    pharmacy?.address?.zipcode,
                ].filter(Boolean).join(", ")),
                electronicPrescribing: Boolean(pharmacy?.erxEnabled),
                default: Boolean(pharmacy?.makeDefault),
            }));
            return { items, nextCursor: null };
        },
    });
});
