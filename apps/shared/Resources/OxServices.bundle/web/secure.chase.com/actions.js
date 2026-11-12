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
    const ORIGIN = "https://secure.chase.com";
    const DASHBOARD_URL = `${ORIGIN}/web/auth/dashboard`;
    const EXECUTION_URL = `${ORIGIN}/robots.txt`;
    const jpmcHeaders = (post = false) => {
        const h = {
            "x-jpmc-channel": "id=C30",
            "x-jpmc-csrf-token": "NONE",
            "x-jpmc-client-request-id": crypto.randomUUID(),
        };
        if (post)
            h["content-type"] = "application/x-www-form-urlencoded; charset=UTF-8";
        return h;
    };
    const postForm = async (path, body) => {
        const res = await retryFetch(ORIGIN + path, {
            method: "POST",
            headers: jpmcHeaders(true),
            credentials: "include",
            cache: "no-store",
            body: body ? new URLSearchParams(body).toString() : "",
        });
        if (res.status === 401)
            throw signedOut();
        if (!res.ok)
            throw new Error(`POST ${path} HTTP ${res.status}`);
        return res.json();
    };
    const getJson = async (path) => {
        const res = await retryFetch(ORIGIN + path, {
            headers: jpmcHeaders(),
            credentials: "include",
        });
        if (res.status === 401)
            throw signedOut();
        if (!res.ok)
            throw new Error(`GET ${path} HTTP ${res.status}`);
        return res.json();
    };
    const signedOut = () => new Error("Chase session is signed out. Run login, rediscover sessions, then retry.");
    const fetchBootstrap = async () => postForm("/svc/rl/accounts/l4/v1/app/data/list");
    const accountTilesOf = (bootstrap) => {
        const cache = Array.isArray(bootstrap?.cache) ? bootstrap.cache : [];
        const tiles = cache.find((c) => String(c?.url ?? "").includes("dashboard/tiles/list"));
        const list = tiles?.response?.accountTiles;
        return Array.isArray(list) ? list : [];
    };
    const mapTile = (t) => ({
        accountId: t?.accountId ?? null,
        nickname: t?.nickname ?? null,
        mask: t?.mask ?? null,
        cardType: t?.cardType ?? null,
        accountTileType: t?.accountTileType ?? null,
        currentBalance: t?.tileDetail?.currentBalance ?? null,
        availableBalance: t?.tileDetail?.availableBalance ?? null,
        nextPaymentDueDate: t?.tileDetail?.nextPaymentDueDate ?? null,
        nextPaymentAmount: t?.tileDetail?.nextPaymentAmount ?? null,
        pastDueAmount: t?.tileDetail?.pastDueAmount ?? null,
        paymentDueDays: t?.tileDetail?.paymentDueDays ?? null,
        dueStatus: t?.tileDetail?.dueStatus ?? null,
        lockStatus: t?.tileDetail?.creditCardLockStatus ?? null,
        closed: t?.tileDetail?.closed ?? null,
    });
    const cleanText=value=>String(value??'').replace(/[\u200B-\u200D\uFEFF]/g,'').replace(/\s+/g,' ').trim();
    const usable=element=>{
        if(!element||element.disabled||element.readOnly||element.type==='hidden')return false;
        if(element.closest('[hidden], [aria-hidden="true"], [inert]'))return false;
        const style=element.ownerDocument.defaultView.getComputedStyle(element);
        return style.display!=='none'&&style.visibility!=='hidden';
    };
    const waitForStep=async(detectors,timeout=20000)=>{
        const end=Date.now()+timeout;
        while(Date.now()<end){
            for(const [kind,detect] of Object.entries(detectors)){const match=detect();if(match)return {kind,match};}
            await new Promise(resolve=>setTimeout(resolve,200));
        }
        return {kind:'unknown',match:null};
    };
    const typeInto=(field,value)=>{
        const doc=field.ownerDocument,win=doc.defaultView;
        field.focus();field.select?.();
        if(!doc.execCommand('insertText',false,value)||field.value!==value){
            Object.getOwnPropertyDescriptor(win.HTMLInputElement.prototype,'value').set.call(field,value);
            field.dispatchEvent(new win.InputEvent('input',{bubbles:true,inputType:'insertText',data:value}));
        }
        field.dispatchEvent(new win.Event('change',{bubbles:true}));
    };
    const pageError=root=>[...root.querySelectorAll('[role="alert"], [aria-live="assertive"], [aria-live="polite"]')].filter(usable).map(e=>cleanText(e.innerText)).filter(Boolean).join(' | ').slice(0,200);
    const chaseDoc=()=>{try{return document.getElementById('logonbox')?.contentDocument||document;}catch{return document;}};
    const chaseLoginStep=()=>waitForStep({
        challenge:()=>{const d=chaseDoc();return [...d.querySelectorAll('input[autocomplete="one-time-code"],iframe[src*="captcha"]')].find(usable)||(/verify your identity|verification code|security code|verify you are human/i.test(d.body?.innerText||'')?d.body:null);},
        credentials:()=>{const d=chaseDoc(),username=d.getElementById('userId-input-field-input'),password=d.getElementById('password-input-field-input'),submit=d.getElementById('signin-button'),root=username?.closest('form');return usable(username)&&usable(password)&&usable(submit)&&root?.contains(password)&&root?.contains(submit)?{username,password,submit,root}:null;}
    });
    action('login',{async invoke(input,context){
        const step=await chaseLoginStep();
        if(step.kind==='unknown'){
            const data=await fetchBootstrap();
            if(data?.personId)return null;
            throw Error('Chase sign-in screen is not ready; no credentials submitted');
        }
        if(step.kind!=='credentials')return null;
        if(!input?.account||input.account.serviceID!=='web:secure.chase.com')return null;
        if(pageError(step.match.root))throw Error('Chase sign-in form reports an error; stopped without retrying');
        const account=await context.secret(input.account);
        typeInto(step.match.username,account.username);
        typeInto(step.match.password,account.password);
        if(!usable(step.match.submit))throw Error('Chase sign-in button unavailable');
        step.match.submit.click();
        return null;
    }});
    action('listSessions', { async invoke() {
            let d;
            try {
                d = await fetchBootstrap();
            }
            catch (error) {
                if (error?.message === signedOut().message)
                    return [];
                throw error;
            }
            if (!d?.personId)
                throw Error('Chase account identity unavailable');
            return [{ id: String(d.personId), label: 'Chase ' + String(d.personId), url: EXECUTION_URL }];
        } });
    action("listAccounts", {
        async invoke() {
            const data = await fetchBootstrap();
            if (!data?.personId)
                throw signedOut();
            return { items: accountTilesOf(data).map(mapTile), nextCursor: null };
        },
    });
    action("getAccount", {
        async invoke({ accountId } = {}) {
            if (!accountId)
                throw new Error("getAccount requires accountId");
            const data = await postForm("/svc/rr/accounts/secure/v2/account/detail/card/list", {
                accountId: String(accountId),
            });
            if (data?.code && data.code !== "SUCCESS")
                throw new Error(`Chase returned ${data.code}`);
            const d = data?.detail ?? {};
            return {
                accountId: data?.accountId ?? accountId,
                nickname: data?.nickname ?? null,
                mask: data?.mask ?? null,
                cardType: d?.cardType ?? null,
                currentBalance: d?.currentBalance ?? null,
                availableCredit: d?.availableCredit ?? null,
                creditLimit: d?.creditLimit ?? null,
                lastStmtBalance: d?.lastStmtBalance ?? null,
                lastStmtDate: d?.lastStmtDate ?? null,
                remainingStmtBalance: d?.remainingStmtBalance ?? null,
                pendingChargesAmount: d?.pendingChargesAmount ?? null,
                nextPaymentDueDate: d?.nextPaymentDueDate ?? null,
                nextPaymentAmount: d?.nextPaymentAmount ?? null,
                pastDueAmount: d?.pastDueAmount ?? null,
                lastPaymentAmount: d?.lastPaymentAmount ?? null,
                lastPaymentDate: d?.lastPaymentDate ?? null,
                purchaseAPR: d?.purchaseAPR ?? null,
                cashAPR: d?.cashAPR ?? null,
                autoPayEnrolled: d?.autoPayEnrolled ?? null,
                rewardsEligible: d?.rewardsEligible ?? null,
                lockStatus: d?.lockStatus ?? null,
                closed: d?.closed ?? null,
            };
        },
    });
    const mapTxn = (a) => {
        const m = a?.merchantDetails ?? {};
        const enriched = Array.isArray(m.enrichedMerchants) ? m.enrichedMerchants[0] : null;
        const raw = m.rawMerchantDetails ?? {};
        return {
            id: a?.sorTransactionIdentifier ?? a?.derivedUniqueTransactionIdentifier ?? null,
            status: a?.transactionStatusCode ?? null,
            pending: a?.transactionStatusCode === "Pending",
            date: a?.transactionDate ?? null,
            postDate: a?.transactionPostDate ?? null,
            amount: a?.transactionAmount ?? null,
            creditDebitCode: a?.creditDebitCode ?? null,
            type: a?.etuStandardTransactionTypeName ?? null,
            typeGroup: a?.etuStandardTransactionTypeGroupName ?? null,
            expenseCategory: a?.etuStandardExpenseCategoryCode ?? null,
            merchantName: enriched?.merchantName ?? raw?.merchantDbaName ?? null,
            merchantCity: enriched?.merchantCityName ?? raw?.merchantCityName ?? null,
            merchantState: enriched?.merchantStateCode ?? raw?.merchantStateCode ?? null,
            merchantCategory: raw?.merchantCategoryName ?? null,
            earnedRewardsAmount: a?.earnedRewardsAmount ?? null,
            last4CardNumber: a?.last4CardNumber ?? null,
            disputed: a?.transactionDisputeIndicator ?? null,
        };
    };
    const pad = (n) => String(n).padStart(2, "0");
    const fmtDate = (d) => `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
    action("listTransactions", {
        async invoke({ accountId, limit = 50, cursor, startDate, endDate } = {}) {
            if (!accountId)
                throw new Error("listTransactions requires accountId");
            const count = Math.max(1, Math.min(Number(limit) || 50, 100));
            const end = endDate ? String(endDate) : fmtDate(new Date());
            const start = startDate ? String(startDate) : (() => {
                const d = new Date();
                d.setFullYear(d.getFullYear() - 2);
                return fmtDate(d);
            })();
            const params = new URLSearchParams({
                "digital-account-identifier": String(accountId),
                "provide-available-statement-indicator": "true",
                "record-count": String(count),
                "sort-order-code": "D",
                "sort-key-code": "T",
                "account-activity-start-date": start,
                "account-activity-end-date": end,
            });
            if (cursor)
                params.set("pagination-contextual-text", String(cursor));
            const data = await getJson(`/svc/rr/accounts/secure/gateway/credit-card/transactions/inquiry-maintenance/etu-transactions/v4/accounts/transactions?${params}`);
            const activities = Array.isArray(data?.activities) ? data.activities : [];
            const nextCursor = data?.moreRecordsIndicator && data?.paginationContextualText
                ? String(data.paginationContextualText)
                : null;
            return {
                items: activities.map(mapTxn),
                nextCursor,
            };
        },
    });
    action("getRewards", {
        async invoke() {
            const data = await postForm("/svc/rr/accounts/secure/card/rewards/v2/summary/list");
            if (data?.code && data.code !== "SUCCESS")
                throw new Error(`Chase returned ${data.code}`);
            const summary = Array.isArray(data?.cardRewardsSummary) ? data.cardRewardsSummary : [];
            const items = summary.map((s) => ({
                accountId: s?.accountId ?? null,
                nickname: s?.nickname ?? null,
                mask: s?.mask ?? null,
                cardType: s?.cardType ?? null,
                rewardsType: s?.rewardsType ?? null,
                cardRewardType: s?.cardRewardType ?? null,
                balance: s?.balance ?? null,
                currentRewardsBalance: s?.currentRewardsBalance ?? null,
                rewardsDollarBalance: s?.rewardsDollarBalance ?? null,
                asOfDate: s?.asOfDate ?? null,
            }));
            return { items, nextCursor: null };
        },
    });
    const PAYEE_TYPES = [
        "AUTO_LEASE", "AUTO_LOAN", "BUSINESS_LOAN", "COMMERCIAL_LOAN", "CREDIT_CARD",
        "HELOC", "HOME_EQUITY_LOAN", "MERCHANT", "MORTGAGE", "PERSONAL_LOAN",
        "STUDENT_LOAN", "CREDIT_FACILITY",
    ].join(",");
    action("listPayees", {
        async invoke() {
            const data = await postForm("/svc/rr/payments/secure/v1/billpay/merchantmultipayment/payee/list", {
                groupViewType: "ALL",
                payeeTypesFilter: PAYEE_TYPES,
            });
            if (data?.code && data.code !== "SUCCESS")
                throw new Error(`Chase returned ${data.code}`);
            const payees = data?.payees && typeof data.payees === "object" ? data.payees : {};
            const items = Object.values(payees).map((p) => ({
                payeeId: p?.payeeId ?? null,
                payeeName: p?.payeeName ?? null,
                payeeNickname: p?.payeeNickname ?? null,
                payeeLabel: p?.payeeLabel ?? null,
                payeeAccountMask: p?.payeeAccountMask ?? null,
                payeeType: p?.payeeType ?? null,
                nextPaymentDate: p?.nextPaymentDate ?? null,
                nextPaymentAmount: p?.nextPaymentAmount ?? null,
                paymentDueInDays: p?.paymentDueInDays ?? null,
                blocked: p?.blocked ?? null,
                paidInFull: p?.paidInFull ?? null,
            }));
            return { items, nextCursor: null };
        },
    });
    const initializePaymentWidgets=async()=>{
        const end=Date.now()+20000;
        while(Date.now()<end){
            if(customElements.get('mds-button'))return;
            const registry=window.MDSRegistry;
            if(document.readyState!=='loading'&&registry?.components?.['mds-button']&&typeof registry.browserIsReady==='function')registry.browserIsReady();
            if(customElements.get('mds-button'))return;
            await new Promise(r=>setTimeout(r,150));
        }
        throw Error('Chase payment component library did not initialize');
    };
    const paymentWait=async(fn,ms=20000)=>{const end=Date.now()+ms;while(Date.now()<end){const value=fn();if(value)return value;await new Promise(r=>setTimeout(r,150));}throw Error('Chase payment view did not become ready');};
    action('getCardPaymentActivity',{async invoke(args){
        await initializePaymentWidgets();
        const route='#/dashboard/payBillsArea/paymentsActivity/selectPayee;payeeId='+encodeURIComponent(String(args.payeeId))+';payeeType=CREDIT_CARD';
        const before=[...document.querySelectorAll('table')].find(t=>/Payment date/.test(t.textContent)&&/Status/.test(t.textContent));
        const changed=location.hash!==route;if(changed)location.hash=route;
        const table=await paymentWait(()=>{if(location.hash!==route)return null;const t=[...document.querySelectorAll('table')].find(t=>/Payment date/.test(t.textContent)&&/Status/.test(t.textContent));return t&&(!changed||!before||!before.isConnected)?t:null;});
        const rows=[...table.querySelectorAll('tr')].filter(row=>row.querySelectorAll('td').length>=4);
        return {items:rows.slice(0,args.limit).map(row=>{const c=[...row.querySelectorAll('td')];return {date:c[0].textContent.replace(/\s+/g,' ').trim(),status:c[1].textContent.trim(),amountLabel:c[3].textContent.replace(/\s+/g,' ').trim()};}),nextCursor:null,coverage:'Displayed payment history; pending entries included'};
    }});
    action('prepareCardPayment',{async invoke(args){
        const data=await postForm('/svc/rr/payments/secure/v2/billpay/multi/payment/add/options',{payeeId:String(args.payeeId)});
        if(data.code&&data.code!=='SUCCESS')throw Error('Chase payment options unavailable');
        const o=data.creditCardMultiPayBillOptions;
        const current=o?.fundingOptions?.find(x=>x.optionType==='CURRENT_BALANCE'&&!x.disabled);
        const funding=o?.fundingAccounts?.find(x=>String(x.accountId)===String(args.fundingAccountId));
        if(!current||Math.round(current.amount*100)!==Math.round(args.expectedAmount*100))throw Error('Current balance changed; review the new amount before preparing');
        if(!funding||o.paymentSuppressed)throw Error('Selected funding account or payment is unavailable');
        if(!o.dateOptions?.includes(args.paymentDate))throw Error('Requested payment date is unavailable');
        await initializePaymentWidgets();
        const route='#/dashboard/overview/index;flyout=manageMultipleBillsPayCard,'+encodeURIComponent(String(args.payeeId))+',BAC,microApp';
        if(location.hash!==route)location.hash=route;
        const root=await paymentWait(()=>{const e=document.getElementById('paymentDueAmountOption_0_0');const heading=document.getElementById('creditCardPayeeName');return e?.shadowRoot&&heading?.textContent.trim()===o.payeeLabel?e:null;});
        const radio=root.shadowRoot.querySelector('input[type="radio"][value="'+String(current.optionId)+'"]');
        if(!radio||radio.disabled)throw Error('Current balance selection is unavailable');
        radio.click();
        await paymentWait(()=>radio.checked&&root.getAttribute('selected-radio')===String(current.optionId),5000);
        const source=document.getElementById('fundingAccount_0');
        if(source?.getAttribute('value')!==String(args.fundingAccountId)){
            const button=source?.shadowRoot?.querySelector('button');if(!button)throw Error('Funding account selector unavailable');button.click();
            const option=source.shadowRoot.querySelector('mds-select-option[value="'+String(args.fundingAccountId)+'"]');
            const target=option?.shadowRoot?.querySelector('[role="option"]')||option;
            if(!target)throw Error('Requested funding account option missing');target.click();
            await paymentWait(()=>source.getAttribute('value')===String(args.fundingAccountId),5000);
        }
        const date=document.getElementById('transactionDueDate_0');const expected=args.paymentDate.slice(4,6)+'/'+args.paymentDate.slice(6,8)+'/'+args.paymentDate.slice(0,4);
        if(date?.getAttribute('selected-date')!==expected)throw Error('Payment date needs manual review; no payment submitted');
        const button=document.getElementById('verify-bill-payments')?.shadowRoot?.querySelector('button');
        const b=button?.getBoundingClientRect();const style=button?getComputedStyle(button):null;
        if(!button||button.disabled||!b||b.width<60||b.height<20||parseFloat(style.fontSize)<12||style.visibility==='hidden'||style.display==='none')throw Error('Final payment controls are not readable and usable; no payment submitted');
        return {payee:o.payeeLabel,amount:current.amount,funding:String(funding.accountMask),paymentDate:args.paymentDate,submitted:false,readabilityVerified:true};
    }});
    action('getPaymentOptions',{async invoke({payeeId}){
        const data=await postForm('/svc/rr/payments/secure/v2/billpay/multi/payment/add/options',{payeeId:String(payeeId)});
        if(data.code&&data.code!=='SUCCESS')throw Error('Chase payment options returned '+data.code);
        const o=data.creditCardMultiPayBillOptions;if(!o||!Array.isArray(o.fundingAccounts)||!Array.isArray(o.fundingOptions)||!Array.isArray(o.dateOptions))throw Error('Payment options incomplete');
        return {payeeLabel:String(o.payeeLabel||''),paymentSuppressed:!!o.paymentSuppressed,fundingAccounts:o.fundingAccounts.map(a=>({accountId:a.accountId,label:String(a.accountMask||a.nickName||'').replace(/\d(?=\d{4})/g,'*'),external:!!a.external,default:!!a.defaultFlag})),amountOptions:o.fundingOptions.map(x=>({type:String(x.optionType),amount:typeof x.amount==='number'?x.amount:null,disabled:!!x.disabled})),availableDates:o.dateOptions.map(String)};
    }});
    action("createPayment", {
        async invoke({ payeeId, amount, paymentDate, fundingAccountId, paymentOption } = {}) {
            if (!payeeId)
                throw new Error("createPayment requires payeeId");
            const optionsData = await postForm("/svc/rr/payments/secure/v2/billpay/multi/payment/add/options", {
                payeeId: String(payeeId),
            });
            if (optionsData?.code && optionsData.code !== "SUCCESS")
                throw new Error(`Chase returned ${optionsData.code}`);
            const opts = optionsData?.creditCardMultiPayBillOptions ?? {};
            const fundingAccounts = Array.isArray(opts.fundingAccounts) ? opts.fundingAccounts : [];
            const fundingOptions = Array.isArray(opts.fundingOptions) ? opts.fundingOptions : [];
            const dateOptions = Array.isArray(opts.dateOptions) ? opts.dateOptions : [];
            const account = fundingAccountId
                ? fundingAccounts.find((a) => String(a?.accountId) === String(fundingAccountId))
                : (fundingAccounts.find((a) => a?.defaultFlag) ?? fundingAccounts[0]);
            if (!account)
                throw new Error("No matching funding account; call listAccounts/options to pick a fundingAccountId");
            const usable = fundingOptions.filter((o) => !o?.disabled);
            let chosen = paymentOption
                ? usable.find((o) => o?.optionType === paymentOption)
                : (amount != null ? usable.find((o) => o?.amount === Number(amount)) : undefined);
            if (!chosen)
                chosen = usable.find((o) => o?.optionType === "OTHER_AMOUNT");
            if (!chosen)
                throw new Error("No usable payment option for this payee");
            const payAmount = amount != null ? Number(amount) : chosen?.amount;
            if (payAmount == null)
                throw new Error("createPayment requires amount for OTHER_AMOUNT");
            const payDate = paymentDate ? String(paymentDate) : dateOptions[0];
            if (!payDate)
                throw new Error("No available payment date");
            const validateData = await postForm("/svc/rr/payments/secure/v3/billpay/multi/payment/add/validate", {
                "creditCardDetail[0].fundingAccountId": String(account.accountId),
                "creditCardDetail[0].amount": String(payAmount),
                "creditCardDetail[0].paymentDate": payDate,
                "creditCardDetail[0].orderId": "1",
                "creditCardDetail[0].payeeId": String(payeeId),
                "creditCardDetail[0].accountId": "",
                "creditCardDetail[0].paymentOptionId": String(chosen.optionId),
                "creditCardDetail[0].optionId": "",
            });
            if (validateData?.errorStatus)
                throw new Error("Chase rejected the payment at validation");
            const formId = validateData?.formId;
            if (!formId)
                throw new Error("Chase did not return a formId; payment not submitted");
            const result = await postForm("/svc/wr/payments/secure/v2/billpay/multi/payment/add", {
                formId: String(formId),
            });
            if (result?.code && result.code !== "SUCCESS")
                throw new Error(`Chase returned ${result.code}`);
            const payment = (Array.isArray(result?.payments) ? result.payments : [])[0] ?? {};
            return {
                ok: true,
                paymentId: payment?.paymentId ?? null,
                status: payment?.status ?? null,
                amount: payment?.amount ?? payAmount,
                paymentDate: payment?.paymentDate ?? payDate,
                processDate: payment?.processDate ?? null,
                payeeLabel: payment?.payeeLabel ?? null,
                fundingAccountMask: payment?.fundingAccountMask ?? null,
            };
        },
    });
});
