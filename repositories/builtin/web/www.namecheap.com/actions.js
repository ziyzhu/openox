const cleanText = value => String(value ?? "").replace(/\s+/g, " ").trim();

const retryFetch = async (input, init, options) => {
  const retries = options?.retries ?? 3;
  const delay = options?.delay ?? 400;
  const factor = options?.factor ?? 2;
  for (let attempt = 0; ; attempt++) {
    try {
      const response = await window.fetch(input, init);
      const retryable = response.status === 408 || response.status === 429
        || (response.status >= 500 && response.status <= 599);
      if (response.ok || !retryable || attempt >= retries) return response;
      console.log(`retryFetch: status ${response.status}, attempt ${attempt + 1}/${retries}`);
    } catch (error) {
      const message = String(error?.message ?? "");
      const retryable = message.includes("Load failed")
        || message.includes("NetworkError")
        || message.includes("Failed to fetch");
      if (!retryable || attempt >= retries) throw error;
      console.log(`retryFetch: network ${JSON.stringify(message)}, attempt ${attempt + 1}/${retries}`);
    }
    await new Promise(resolve => setTimeout(resolve, delay * Math.pow(factor, attempt)));
  }
};

window.ox.install(({ action }) => {
    const normalizedDomain = (value) => {
        const domain = String(value ?? "").trim().toLowerCase().replace(/\.$/, "");
        const labels = domain.split(".");
        const valid = domain.length <= 253 && labels.length >= 2 && labels.every((label) => label.length >= 1 && label.length <= 63 && /^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/.test(label));
        if (!valid)
            throw new Error("Enter a valid fully qualified domain name");
        return domain;
    };
    const amount = (value) => {
        const number = Number(value);
        return Number.isFinite(number) && number >= 0 ? number : null;
    };
    const optionalText = (value) => cleanText(value) || null;
    action("getDomainAvailability", {
        async invoke({ domain }) {
            const normalized = normalizedDomain(domain);
            const url = new URL("https://domains.revved.com/v1/domainStatus");
            url.searchParams.set("whois", "true");
            url.searchParams.set("domains", normalized);
            const response = await retryFetch(url.href);
            if (!response.ok)
                throw new Error(`Namecheap returned HTTP ${response.status}`);
            const data = await response.json();
            const status = Array.isArray(data?.status)
                ? data.status.find((item) => String(item?.name ?? "").toLowerCase() === normalized)
                : null;
            if (!status || typeof status.available !== "boolean") {
                throw new Error(`Namecheap did not return availability for ${normalized}`);
            }
            const fee = status.fee ?? {};
            const renewalFee = status.renewalFee ?? {};
            const registrationPrice = amount(fee.retailAmount) ?? amount(fee.amount);
            const renewalPrice = amount(renewalFee.retailAmount) ?? amount(renewalFee.amount);
            const result = {
                domain: normalized,
                available: status.available,
                premium: Boolean(status.premium),
                lookupType: optionalText(status.lookupType),
                reason: optionalText(status.reason),
                createdYear: amount(status.whois?.createdYear ?? status.extra?.createdYear),
                registrar: optionalText(status.extra?.registrar),
                registrationPrice,
                renewalPrice,
                currency: optionalText(fee.currency ?? renewalFee.currency),
                url: `https://www.namecheap.com/domains/registration/results/?domain=${encodeURIComponent(normalized)}`,
            };
            console.log(`namecheap getDomainAvailability domain=${normalized} available=${result.available} premium=${result.premium}`);
            return result;
        },
    });
});
