(() => {
  // services/builtin/web/frontierdermpartners.modmedapp.com/actions.ts
  var ORIGIN = "https://frontierdermpartners.modmedapp.com";
  var PORTAL = "/patient-portal";
  var HEADER_SELECTOR = "ageInMonths,ageInYears,dateOfBirth,email,encryptedId,fullName,fullNameComplete,gender,inactive,loginEnabled,mrn,pmsId,pqrsId,sex,thumbnailUrl,preferredPhone,nameLastFirst,username,portalEnabled,mustResetPassword,passwordAge,passwordExpired,patientAdditionalInfo(emailOptIn),userPasswordResetRequired,passwordDate,userGraceLoginLeft,hideEmaPasswordServices,timeZone";
  var PROFILE_SELECTOR = "id,allowLeaveMessage,caretakerFullName,caretakerPhoneNumber,cellPhone(fullPhoneNumberFormatted),city,country,county,dateOfBirth,dateOfDeath,deceased,differences,driversLicenseNumber,driversLicenseState,email,emailAlt,emergencyContactFullName,emergencyContactPhoneNumber,employerName,endDate,ethnicGroup,ethnicGroupDetails,firstName,homePhone(fullPhoneNumberFormatted),industry(id,name,value,code),languagePrefStandardized,languagePreference,lastName,maritalStatus,middleName,nickName,occupation(id,name,value,code),patientAdditionalInfoDto(emailOptIn),patientGenderDemographics(genderIdentity,genderIdentityOtherText,sexualOrientation,patientPreferredPronoun,id,sexualOrientationOtherText),seasonalAddress(street1,street2,city,state,country,zipcode,startDate,endDate),phoneNumberReadonly,placeOfBirthCity,placeOfBirthCountry,placeOfBirthState,placeOfBirthZipcode,preferredContactMethod,preferredPhoneType,prefix,previousAddress,previousName,races,sex,socialSecurityNumber,spouseFullName,spousePhoneNumber,startDate,state,status,street1,street2,suffix,welcomeText,workPhone(fullPhoneNumberFormatted),hasPmsId,patientPortalDemographicUpdatesForMaverickEnabled,zipcode";
  var MEDICATION_SELECTOR = "id,status,dermHistory(id,shOccupation,otherMedications,medicationNone),firmUserCurrentMedications(drugName,id,dateEnded,dateStarted,medicationStatus,dose,doseForm,frequency,genericName,indication,units,strength,drugNameID,route,rx,duringVisit,deletableByPatient,pendingDeletion,location,locationSpecific,routeLocationList)";
  var PHARMACY_SELECTOR = "id,erxEnabled,name,phoneNumber,faxNumber,address(city,country,fullStreetAddress,street1,street2,street3,zipcode,state),makeDefault";
  var INSURANCE_SELECTOR = "groupNumber,insurancePhoneNumber,guarantorFirstName,guarantorLastName,guarantorHomePhoneNumber,guarantorWorkPhoneNumber";
  var ALLERGY_SELECTOR = "id,status,currentAllergies(id,displayName,allergenTypeAsString,deletableByPatient,otherResponse,severity,dateRecorded,fdbAllergenId,status,fdbAllergenTypeId,fdbAllergenIdType,fdbAllergenDesc,description,allergyResponseOtherValue,pendingDeletion,responses,responseValues,dateStarted,dateRecorded,dateEnded,otherResponse),dermHistory(pedBirthLbs,pedBirthOz,otherAllergies,allergyNkda)";
  var BALANCE_SELECTOR = "patientBalanceInfoBeanList(unallocatedAmount,outstandingBalance,taxpayerIdentificationNumber,facility(additionalInfo(locationDisplayName),address(fullStreetAddress)))";
  var string = (value) => value == null ? "" : String(value);
  var optionalString = (value) => value == null || value === "" ? null : String(value);
  var optionalNumber = (value) => {
    const number = Number(value);
    return value == null || !Number.isFinite(number) ? null : number;
  };
  var install = ({ action, retryFetch, log }) => {
    let navigationTail = Promise.resolve();
    const withNavigation = async (work) => {
      const previous = navigationTail;
      let release = () => {};
      navigationTail = new Promise((resolve) => {
        release = resolve;
      });
      await previous.catch(() => {});
      try {
        return await work();
      } finally {
        release();
      }
    };
    const requestJson = async (url) => {
      const response = await retryFetch(url, {
        credentials: "include",
        headers: { Accept: "application/json" }
      });
      const text = await response.text();
      if (response.status === 401 || response.status === 403) {
        throw new Error(`ModMed sign-in required (HTTP ${response.status})`);
      }
      if (!response.ok)
        throw new Error(`ModMed HTTP ${response.status}`);
      try {
        return text ? JSON.parse(text) : null;
      } catch {
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
      return Array.from(document.querySelectorAll("a[href]")).some((candidate) => {
        try {
          return new URL(candidate.href, location.href).pathname.startsWith(`${PORTAL}/`);
        } catch {
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
      const link = Array.from(document.querySelectorAll("a[href]")).find((candidate) => {
        try {
          return new URL(candidate.href, location.href).pathname === path;
        } catch {
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
        const alternate = path.endsWith("/upcoming-visits") ? `${PORTAL}/appointments/past-appointments` : `${PORTAL}/appointments/upcoming-visits`;
        navigateSpa(alternate);
        await new Promise((resolve) => setTimeout(resolve, 150));
      }
      const pending = capture(pattern, { timeoutMs: 12000, replayLatest: false });
      navigateSpa(path);
      try {
        const body = await pending;
        log(`${label}: captured portal response`);
        return body;
      } catch {
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
      } catch (error) {
        if (await waitForPortal())
          return captureRoute(path, pattern, label);
        throw error;
      }
    };
    action("getSignInUrl", {
      async invoke() {
        return { url: `${ORIGIN}/ema/patient-login` };
      }
    });
    action("getSignInState", {
      async invoke() {
        if (portalReady())
          return { signedIn: true };
        try {
          const header = await requestJson(patientHeaderUrl());
          return { signedIn: Boolean(header?.id && header?.portalEnabled !== false) };
        } catch (error) {
          if (/sign-in required \(HTTP (?:401|403)\)/.test(String(error?.message ?? error))) {
            return { signedIn: await waitForPortal() };
          }
          if (await waitForPortal())
            return { signedIn: true };
          throw error;
        }
      }
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
          races: Array.isArray(body?.races) ? body.races.map(string).filter(Boolean) : []
        };
      }
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
            "sorting.sortOrder": "desc"
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
            timeZone: optionalString(visit?.facility?.timeZone)
          },
          visitNoteUrl: visit?.visitNotePdfUrl ? new URL(String(visit.visitNotePdfUrl), ORIGIN).toString() : null
        }));
        return { items, nextCursor: null };
      }
    });
    action("getMedicationHistory", {
      async invoke() {
        const body = await inheritedOrFallback(`${PORTAL}/my-health/medications`, /\/ema\/ws\/v3\/portal\/patient\/\d+\/medicalHistory(?:\?|$)/, "getMedicationHistory", async () => {
          const id = await patientId();
          const query = new URLSearchParams({ selector: MEDICATION_SELECTOR });
          return requestJson(`${ORIGIN}/ema/ws/v3/portal/patient/${id}/medicalHistory?${query}`);
        });
        const items = (Array.isArray(body?.firmUserCurrentMedications) ? body.firmUserCurrentMedications : []).map((medication) => ({
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
          deletableByPatient: Boolean(medication?.deletableByPatient)
        }));
        return { noneReported: Boolean(body?.dermHistory?.medicationNone), items };
      }
    });
    action("listProblems", {
      async invoke() {
        const body = await inheritedOrFallback(`${PORTAL}/my-health/problem-list`, /\/ema\/ws\/v3\/problemListItem(?:\?|$)/, "listProblems", async () => {
          const id = await patientId();
          return requestJson(`${ORIGIN}/ema/ws/v3/problemListItem?paging.pageNumber=1&paging.pageSize=10&sorting.sortBy=dateDiagnosed&sorting.sortOrder=asc&selector=description&where=patient==%22${id}%22`);
        });
        const items = (Array.isArray(body) ? body : []).map((problem) => ({
          id: string(problem?.id),
          description: string(problem?.description)
        }));
        return { items, nextCursor: null };
      }
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
          recordedAllergyCount: Array.isArray(body?.currentAllergies) ? body.currentAllergies.length : 0
        };
      }
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
            "sorting.sortOrder": "desc"
          })}`)
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
        } else {
          try {
            [balances, statements] = await load();
          } catch (error) {
            if (!await waitForPortal())
              throw error;
            [balances, statements] = await captureBilling();
          }
        }
        const accounts = (Array.isArray(balances) ? balances : []).flatMap((configuration) => (Array.isArray(configuration?.patientBalanceInfoBeanList) ? configuration.patientBalanceInfoBeanList : []).map((balance) => ({
          id: string(balance?.taxpayerIdentificationNumber?.encryptedId ?? balance?.facility?.id),
          facility: string(balance?.facility?.additionalInfo?.locationDisplayName ?? balance?.facility?.name),
          address: optionalString(balance?.facility?.address?.fullStreetAddress),
          billingType: optionalString(balance?.taxpayerIdentificationNumber?.billingType),
          outstandingBalance: optionalNumber(balance?.outstandingBalance),
          unallocatedAmount: optionalNumber(balance?.unallocatedAmount),
          paymentType: optionalString(configuration?.payfacCollectPaymentType)
        })));
        const recentStatements = (Array.isArray(statements) ? statements : []).map((statement) => ({
          id: string(statement?.id ?? statement?.statementNumber),
          statementNumber: optionalString(statement?.statementNumber),
          date: string(statement?.statementDate),
          status: optionalString(statement?.status),
          totalDue: optionalNumber(statement?.totalPatientDue),
          oldestAgingBalance: optionalString(statement?.oldestAgingBalance)
        }));
        return { accounts, recentStatements };
      }
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
          policyholderName: optionalString([plan?.policyHolderFirstName, plan?.policyHolderLastName].filter(Boolean).join(" "))
        }));
        return { items, nextCursor: null };
      }
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
            pharmacy?.address?.zipcode
          ].filter(Boolean).join(", ")),
          electronicPrescribing: Boolean(pharmacy?.erxEnabled),
          default: Boolean(pharmacy?.makeDefault)
        }));
        return { items, nextCursor: null };
      }
    });
  };
  var actions_default = install;

  // services/action-runtime.ts
  var patternMatches = (pattern, value) => {
    pattern.lastIndex = 0;
    const matched = pattern.test(value);
    pattern.lastIndex = 0;
    return matched;
  };
  function installFetchCapture(target) {
    const registrations = new Set;
    const recent = [];
    const matching = (url) => Array.from(registrations).filter((registration) => patternMatches(registration.pattern, url));
    const settle = (matched, result) => {
      for (const registration of matched) {
        if (!registrations.delete(registration))
          continue;
        clearTimeout(registration.timeout);
        if ("error" in result)
          registration.reject(result.error);
        else
          registration.resolve(result.value);
      }
    };
    const canReplay = (url) => {
      try {
        const page = new URL(target.location.href);
        const request = new URL(url, page);
        return request.hostname === page.hostname && /^\/(?:api|web_api)\//.test(request.pathname);
      } catch {
        return false;
      }
    };
    const capture = (url, read) => {
      const matched = matching(url);
      const replayable = canReplay(url);
      if (matched.length === 0 && !replayable)
        return;
      const value = read();
      if (replayable) {
        const entry = { url, value };
        recent.push(entry);
        while (recent.length > 32)
          recent.shift();
        value.catch(() => {
          const index = recent.indexOf(entry);
          if (index >= 0)
            recent.splice(index, 1);
        });
      }
      if (matched.length === 0)
        return;
      value.then((value2) => settle(matched, { value: value2 }), (error) => settle(matched, {
        error: new Error(`captured ${url} returned invalid JSON: ${String(error?.message ?? error)}`)
      }));
    };
    target.oxFetchCapture = (pattern, options) => {
      if (options?.replayLatest) {
        for (let index = recent.length - 1;index >= 0; index--) {
          if (patternMatches(pattern, recent[index].url))
            return recent[index].value;
        }
      }
      return new Promise((resolve, reject) => {
        const timeoutMs = options?.timeoutMs ?? 1e4;
        const registration = {};
        registration.pattern = pattern;
        registration.resolve = resolve;
        registration.reject = reject;
        registration.timeout = setTimeout(() => {
          if (!registrations.delete(registration))
            return;
          reject(new Error(`fetch capture timed out after ${timeoutMs}ms for ${pattern}`));
        }, timeoutMs);
        registrations.add(registration);
      });
    };
    const originalFetch = target.fetch.bind(target);
    target.fetch = (input, init) => originalFetch(input, init).then((response) => {
      const url = input instanceof Request ? input.url : String(input);
      capture(url, () => response.clone().json());
      return response;
    });
    const XHR = target.XMLHttpRequest;
    if (!XHR)
      return;
    const urls = new WeakMap;
    const originalOpen = XHR.prototype.open;
    const originalSend = XHR.prototype.send;
    XHR.prototype.open = function(...args) {
      urls.set(this, String(args[1] ?? ""));
      return originalOpen.apply(this, args);
    };
    XHR.prototype.send = function(...args) {
      this.addEventListener("loadend", () => {
        const url = urls.get(this) ?? this.responseURL;
        capture(url, async () => {
          if (this.responseType === "json")
            return this.response;
          return JSON.parse(this.responseText);
        });
      }, { once: true });
      return originalSend.apply(this, args);
    };
  }
  function installService(domain, installer) {
    installFetchCapture(window);
    const log = (msg) => {
      try {
        window.webkit?.messageHandlers?.oxConsole?.postMessage({
          level: "log",
          msg: `[service:${domain}] ${msg}`
        });
      } catch {}
    };
    const retryFetch = async (input, init, opts) => {
      const retries = opts?.retries ?? 3;
      const delay = opts?.delay ?? 400;
      const factor = opts?.factor ?? 2;
      const url = typeof input === "string" ? input : input.url;
      for (let attempt = 0;; attempt++) {
        try {
          const response = await window.fetch(input, init);
          const retryable = response.status === 408 || response.status === 429 || response.status >= 500 && response.status <= 599;
          if (response.ok || !retryable || attempt >= retries)
            return response;
          log(`retryFetch: status ${response.status}, attempt ${attempt + 1}/${retries}, url=${url}`);
        } catch (error) {
          const message = String(error?.message ?? "");
          const retryable = message.includes("Load failed") || message.includes("NetworkError") || message.includes("Failed to fetch");
          if (!retryable || attempt >= retries)
            throw error;
          log(`retryFetch: network ${JSON.stringify(message)}, attempt ${attempt + 1}/${retries}, url=${url}`);
        }
        await new Promise((resolve) => setTimeout(resolve, delay * Math.pow(factor, attempt)));
      }
    };
    const actions = new Map;
    const action = (name, definition) => {
      if (actions.has(name))
        throw new Error(`duplicate action: ${name}`);
      if (typeof definition?.invoke !== "function")
        throw new Error(`action ${name} has no invoke function`);
      actions.set(name, definition.invoke);
    };
    try {
      installer({ action, retryFetch, log });
    } catch (error) {
      log(`service installer threw: ${String(error?.stack ?? error?.message ?? error)}`);
      throw error;
    }
    const invoke = async (name, args) => {
      const handler = actions.get(name);
      if (!handler)
        throw new Error(`unknown action: ${name}`);
      try {
        return await handler(args ?? {});
      } catch (error) {
        log(`action ${JSON.stringify(name)} threw: ${String(error?.stack ?? error?.message ?? error)}`);
        throw new Error(`action ${JSON.stringify(name)} failed: ${String(error?.message ?? error)}`);
      }
    };
    const runtime = {
      callServiceAction: (name, args) => invoke(name, args)
    };
    window.ox = runtime;
  }

  installService("frontierdermpartners.modmedapp.com", actions_default);
})();
