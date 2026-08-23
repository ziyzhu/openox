import type { ActionInstaller } from "../action.ts";
import { cleanText } from "../../../action-lib.ts";

const install: ActionInstaller = ({ action, retryFetch, log }) => {
  const normalizedDomain = (value: unknown): string => {
    const domain = String(value ?? "").trim().toLowerCase().replace(/\.$/, "");
    const labels = domain.split(".");
    const valid = domain.length <= 253 && labels.length >= 2 && labels.every((label) =>
      label.length >= 1 && label.length <= 63 && /^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/.test(label)
    );
    if (!valid) throw new Error("Enter a valid fully qualified domain name");
    return domain;
  };

  const amount = (value: unknown): number | null => {
    const number = Number(value);
    return Number.isFinite(number) && number >= 0 ? number : null;
  };

  const optionalText = (value: unknown): string | null => cleanText(value) || null;

  action("getDomainAvailability", {
    async invoke({ domain }) {
      const normalized = normalizedDomain(domain);
      const url = new URL("https://domains.revved.com/v1/domainStatus");
      url.searchParams.set("whois", "true");
      url.searchParams.set("domains", normalized);
      const response = await retryFetch(url.href);
      if (!response.ok) throw new Error(`Namecheap returned HTTP ${response.status}`);
      const data = await response.json();
      const status = Array.isArray(data?.status)
        ? data.status.find((item: any) => String(item?.name ?? "").toLowerCase() === normalized)
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
      log(`namecheap getDomainAvailability domain=${normalized} available=${result.available} premium=${result.premium}`);
      return result;
    },
  });
};

export default install;
