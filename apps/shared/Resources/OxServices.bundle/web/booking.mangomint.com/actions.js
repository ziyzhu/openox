const BOOKING_URL='https://booking.mangomint.com/183341';
async function readBooking(path,body,locationId){
 const controller=new AbortController(),timer=setTimeout(()=>controller.abort(),12000);
 try{const headers={'Content-Type':'application/json','Accept':'application/json','X-Mt-Booking-CompanyId':'183341','X-Mt-Api-Version-Flags':'GroupServicesAware'};if(locationId!=null)headers['X-Mt-Booking-LocationId']=String(locationId);
 const r=await fetch('/api/v1/booking/'+path,{method:'POST',headers,credentials:'omit',cache:'no-store',body:JSON.stringify(body),signal:controller.signal});if(!r.ok)throw Error('Booking read failed: HTTP '+r.status);return await r.json();}finally{clearTimeout(timer);}
}
async function catalog(args){
 const data=await readBooking('app/startup',{staffId:null,serviceId:null,serviceCategoryId:null,deeplinkToken:null});
 if(data.companyId!==183341||!data.servicesInfo||!data.staffInfo||data.timezoneId!=='America/Los_Angeles')throw Error('Unexpected salon catalog');
 const info=data.servicesInfo,serviceName=args.service||'MENS haircut',service=Object.values(info.servicesById).find(s=>s.name===serviceName);if(!service)throw Error('Requested service is unavailable');
 const labels=serviceName==='MENS haircut'?[args.cutStyle||'Scissor Cut']:['Stylist preference','Average Thickness/Length'];
 const groupIds=info.serviceOptionGroupIdsByServiceId[service.id]||[];
 const options=labels.map(label=>{const o=Object.values(info.serviceOptionsById).find(o=>!o.isArchived&&(o.onlineBookingName||o.name)===label&&groupIds.includes(o.serviceOptionGroupId));if(!o)throw Error('Requested cut option unavailable: '+label);return o;});
 for(const groupId of groupIds){const group=info.serviceOptionGroupsById[groupId];const count=options.filter(o=>o.serviceOptionGroupId===groupId).length;if(count<(group.selectAtLeast||0)||(group.selectAtMost!=null&&count>group.selectAtMost))throw Error('Salon changed required haircut choices; review booking page');}
 const extra=options.reduce((sum,o)=>sum+Number(o.price),0);if(!Number.isFinite(extra))throw Error('Invalid option price');
 const ids=data.staffInfo.staffIdsByServiceId[service.id];if(!Array.isArray(ids))throw Error('Missing stylist catalog');
 const names=['','Mon','Tue','Wed','Thu','Fri','Sat','Sun'];
 const staff=ids.filter(id=>!options.some(o=>o.excludedServiceProviderIds.includes(id))).map(id=>{const s=data.staffInfo.staffById[id],mapping=info.staffServiceMappingByServiceIdAndStaffId[service.id]?.[id];if(!s||!mapping)throw Error('Incomplete stylist pricing');const amount=Number(mapping.customPrice??service.defaultPrice)+extra;if(!Number.isFinite(amount))throw Error('Invalid haircut price');return {id,name:[s.firstName,s.lastName].filter(Boolean).join(' '),price:'$'+amount.toFixed(2).replace(/\.00$/,''),workDays:s.daysWorkedRanges.map(r=>r.beginDayOfWeek===r.endDayOfWeekInclusive?names[r.beginDayOfWeek]:names[r.beginDayOfWeek]+'-'+names[r.endDayOfWeekInclusive]).join(', ')};});
 return {data,service,options,staff,selection:{service:serviceName,cutStyle:serviceName==='MENS haircut'?labels[0]:'Average Thickness/Length; basic styling'}};
}
function dateOffset(iso,days){const d=new Date(iso+'T12:00:00Z');d.setUTCDate(d.getUTCDate()+days);return d.toISOString().slice(0,10);}
function localToday(timeZone){const p=Object.fromEntries(new Intl.DateTimeFormat('en-US',{timeZone,year:'numeric',month:'2-digit',day:'2-digit'}).formatToParts(new Date()).map(x=>[x.type,x.value]));return p.year+'-'+p.month+'-'+p.day;}
function slotTime(value,date){if(typeof value!=='string'||!value.startsWith(date+'T')||!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}$/.test(value))throw Error('Unexpected appointment timestamp');const hour=Number(value.slice(11,13));return (hour%12||12)+':'+value.slice(14,16)+(hour<12?' am':' pm');}
window.ox.install(({action})=>{
 action('getHaircutPrices',{async invoke(args){const c=await catalog(args);return {...c.selection,stylists:c.staff.map(({id,...s})=>s),bookingUrl:BOOKING_URL};}});
 action('getHaircutAvailability',{async invoke(args){const c=await catalog(args),requested=args.stylist||'James';const normalize=s=>s.replace(/\*$/,'').trim().toLowerCase();const staff=c.staff.find(s=>normalize(s.name)===normalize(requested));if(!staff)throw Error('Stylist is not offered for this haircut option: '+requested);
 const weekOffset=args.weekOffset||0,today=localToday(c.data.timezoneId),day=new Date(today+'T12:00:00Z').getUTCDay(),startDate=dateOffset(today,-((day+6)%7)+7*weekOffset);
 const result=await readBooking('service-providers/availability',{startDate,services:[{serviceId:c.service.id,staffId:staff.id,staffCategory:null,additionalStaffId:null,additionalStaffCategory:null,serviceOptionIds:c.options.map(o=>o.id),guestIndex:0}],numDays:7,initialLoad:true,knownClientToken:null,availabilityToken:null},c.data.locationId);
 if(result.searchTimedOut||!result.availabilityByDays)throw Error('Availability search incomplete');
 const days=[];for(let i=0;i<7;i++){const date=dateOffset(startDate,i),d=result.availabilityByDays[date];if(!d)throw Error('Requested calendar date missing: '+date);const keys=['morningAvailableSlots','afternoonAvailableSlots','eveningAvailableSlots'];if(keys.some(k=>!Array.isArray(d[k])))throw Error('Unexpected calendar shape');const times=[...new Set(keys.flatMap(k=>d[k].map(slot=>slotTime(slot.startAtLocal,date))))];if(Boolean(d.slotsAvailable)!==Boolean(times.length))throw Error('Inconsistent availability result');days.push({dateLabel:new Intl.DateTimeFormat('en-US',{timeZone:'UTC',weekday:'long',year:'numeric',month:'long',day:'numeric'}).format(new Date(date+'T12:00:00Z')),times});}
 const mapping=c.data.servicesInfo.staffServiceMappingByServiceIdAndStaffId[c.service.id][staff.id]; const durationMinutes=Number(mapping.customDuration??c.service.defaultDuration)+Number(mapping.customProcessingTimeDuration??c.service.defaultProcessingTimeDuration??0)+Number(mapping.customFinishingTimeDuration??c.service.defaultFinishingTimeDuration??0)+c.options.reduce((sum,o)=>sum+Number(o.duration),0); if(!Number.isInteger(durationMinutes)||durationMinutes<=0)throw Error('Invalid stylist duration');
 return {...c.selection,stylist:staff.name,price:staff.price,durationMinutes,timeZone:c.data.timezoneId,calendarLabel:startDate+' to '+dateOffset(startDate,6),weekOffset,days,checkedAt:new Date().toISOString(),bookingUrl:BOOKING_URL};
 }});
 action('prepareHaircutBooking',{async invoke(args){
 const deadline=Date.now()+25000;const pause=()=>new Promise(r=>setTimeout(r,90));
 const find=(selector,text)=>[...document.querySelectorAll(selector)].find(e=>e.textContent.trim()===text);
 const wait=async(fn,label)=>{while(Date.now()<deadline){const e=fn();if(e)return e;await pause();}throw Error('Booking preparation incomplete: '+label);};
 const click=async(selector,text)=>{const e=await wait(()=>find(selector,text),text);if(e.disabled)throw Error('Disabled booking choice: '+text);e.click();};
 const summary=async()=>{await wait(()=>document.querySelector('input[name=phone]'),'contact review');await wait(()=>document.body.innerText.includes('MENS haircut ($150)'),'review price');const t=document.body.innerText;if(!t.includes('Saturday, November 7, 2026')||!t.includes('with James* at '+args.startTime)||!t.includes('(Scissor Cut)')||!find('button','Book Now'))throw Error('Booking review does not match request');const contactFieldsFilled=[];for(const name of ['phone','firstName','lastName','email']){if(args[name]==null)continue;const fields=document.querySelectorAll('input[name="'+name+'"]');if(fields.length!==1)throw Error('Contact field is not unique: '+name);const e=fields[0];Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value').set.call(e,args[name]);const propsKey=Object.keys(e).find(k=>k.startsWith('__reactProps'));const props=propsKey?e[propsKey]:null;if(typeof props?.onChange!=='function')throw Error('Contact change handler unavailable');props.onChange({currentTarget:e,target:e});contactFieldsFilled.push(name);await pause();}await pause();for(const name of contactFieldsFilled){const v=document.querySelector('input[name="'+name+'"]').value;const norm=x=>name==='phone'?x.replace(/[^0-9]/g,''):x;if(norm(v)!==norm(args[name]))throw Error('Contact field did not persist: '+name);}return {contactFieldsFilled,status:'readyForUserReview_notBooked',date:args.date,startTime:args.startTime,service:'MENS haircut → Scissor Cut; no conditioning',stylist:'James*',price:'$150',durationMinutes:60,cancellationPolicy:'Canceled or rescheduled within 24 hours: 50% of service total. No-show: full price.',bookingUrl:BOOKING_URL};};
 if(document.querySelector('input[name=phone]'))return await summary();
 if(!document.querySelector('[class*=DateStrip_rangeLabel]')) {
 await click('[data-testid=CollapsibleSection_header]','Haircuts');
 await click('[class*=ServiceItem_name__]','MENS haircut');
 const option=await wait(()=>find('[class*=ServiceOptionList_serviceOptionName]','Scissor Cut'),'Scissor Cut option');option.parentElement.parentElement.click();
 await pause();await click('button','Continue');
 await click('[class*=ServiceProviderList_name__]','James*');
 await click('button','No');
 }
 await wait(()=>document.querySelector('[class*=DateStrip_rangeLabel]')?.textContent==='November 2026','November calendar');
 await wait(()=>document.querySelector('[class*=DateSelector_selectedDateTxt]')&&document.querySelector('[class*=TimeofDayGroup_timeGroupName]'),'loaded date availability');
 await click('[class*=DateStrip_dayCtDate]','7');
 await wait(()=>document.querySelector('[class*=DateSelector_selectedDateTxt]')?.textContent.includes('Saturday, November 7, 2026'),'requested calendar date');
 if(!find('[class*=TimeSlot_componentCt]',args.startTime)){const group=await wait(()=>[...document.querySelectorAll('[class*=TimeofDayGroup_timeGroupName]')].find(e=>e.textContent.startsWith('Afternoon:')),'afternoon slots');group.click();}
 await click('[class*=TimeSlot_componentCt]',args.startTime);
 return await summary();
 }});

 action('getBookingPageState',{async invoke(){return {selectedDate:document.querySelector('[class*=DateSelector_selectedDateTxt]')?.textContent||'',reviewVisible:!!document.querySelector('input[name=phone]'),confirmationVisible:document.body.innerText.includes('You’re booked!'),calendarVisible:!!document.querySelector('[class*=DateStrip_rangeLabel]')};}});
});