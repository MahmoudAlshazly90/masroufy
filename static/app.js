'use strict';
const $=s=>document.querySelector(s);
const categories={Food:['أكل ومشروبات','☕'],Transport:['مواصلات','↗'],Shopping:['تسوّق','▧'],Bills:['فواتير','▤'],Health:['صحة','✚'],Education:['تعليم','▥'],Entertainment:['ترفيه','♫'],Other:['أخرى','◈']};
const state={user:null,csrf:'',expenses:[],budgets:[],signup:false,editing:null,deleting:null,view:'overview'};
const esc=s=>String(s).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const money=n=>new Intl.NumberFormat('en-US',{minimumFractionDigits:2,maximumFractionDigits:2}).format(n/100);
const localDate=()=>{const d=new Date();return `${d.getFullYear()}-${String(d.getMonth()+1).padStart(2,'0')}-${String(d.getDate()).padStart(2,'0')}`;};
const monthLabel=m=>new Date(`${m}-15T12:00:00`).toLocaleDateString('ar-EG',{month:'long',year:'numeric'});
const errors={'Incorrect email or password.':'البريد الإلكتروني أو كلمة السر مش صحيحين.','An account with that email already exists.':'الإيميل ده مسجّل بالفعل. جرّب تسجيل الدخول.','Too many attempts. Please try again in 15 minutes.':'محاولات كتير. جرّب تاني بعد 15 دقيقة.','Please sign in to continue.':'سجّل الدخول علشان تكمّل.','Your session could not be verified. Reload and try again.':'حدّث الصفحة وجرب تاني.','Expense not found.':'المصروف مش موجود أو مش متاح لحسابك.'};
async function api(path,method='GET',body){
 let response;
 try{response=await fetch(`/api${path}`,{method,credentials:'same-origin',headers:{'Content-Type':'application/json','X-Requested-With':'Masroufy',...(state.csrf?{'X-CSRF-Token':state.csrf}:{})},...(body===undefined?{}:{body:JSON.stringify(body)})});}
 catch{throw new Error('مش قادرين نوصل للسيرفر. اتأكد إنه شغال وجرب تاني.');}
 const data=await response.json().catch(()=>({error:'حصلت مشكلة في الرد من السيرفر.'}));
 if(!response.ok){if(response.status===401 && state.user){reset();showAuth();toast('انتهت الجلسة. سجّل دخولك تاني.',true);}throw new Error(errors[data.error]||data.error||'حصلت مشكلة. جرّب تاني.');}
 return data;
}
let toastTimer;
function toast(message,bad=false){clearTimeout(toastTimer);$('#toast').textContent=message;$('#toast').classList.toggle('bad',bad);$('#toast').classList.remove('hidden');toastTimer=setTimeout(()=>$('#toast').classList.add('hidden'),4000);}
function reset(){Object.assign(state,{user:null,csrf:'',expenses:[],budgets:[],editing:null,deleting:null});$('#expense-list').replaceChildren();document.querySelectorAll('dialog[open]').forEach(d=>d.close());}
function showAuth(){ $('#loading').classList.add('hidden');$('#app').classList.add('hidden');$('#auth').classList.remove('hidden');}
function mode(signup){state.signup=signup;$('#signup-tab').classList.toggle('active',signup);$('#login-tab').classList.toggle('active',!signup);$('#name-label').classList.toggle('hidden',!signup);$('#confirm-label').classList.toggle('hidden',!signup);$('#auth-name').required=signup;$('#auth-confirm').required=signup;$('#auth-title').textContent=signup?'خلّي البداية على حسابك ✨':'أهلًا برجوعك 👋';$('#auth-description').textContent=signup?'حساب جديد، وخطوة أهدى مع فلوسك.':'سجّل دخولك وكمّل خطتك.';$('#auth-submit').textContent=signup?'إنشاء حساب ←':'تسجيل الدخول ←';$('#auth-password').autocomplete=signup?'new-password':'current-password';$('#auth-error').textContent='';}
$('#login-tab').onclick=()=>mode(false);$('#signup-tab').onclick=()=>mode(true);
$('#toggle-password').onclick=()=>{const input=$('#auth-password');input.type=input.type==='password'?'text':'password';$('#toggle-password').textContent=input.type==='password'?'إظهار':'إخفاء';};
$('#auth-form').onsubmit=async event=>{event.preventDefault();$('#auth-error').textContent='';if(state.signup&&$('#auth-password').value!==$('#auth-confirm').value){$('#auth-error').textContent='كلمة السر وتأكيدها لازم يكونوا زي بعض.';return;}const button=$('#auth-submit');button.disabled=true;try{const data=await api(state.signup?'/signup':'/login','POST',{name:$('#auth-name').value.trim(),email:$('#auth-email').value.trim(),password:$('#auth-password').value});state.user=data.user;state.csrf=data.csrf;$('#auth-password').value='';$('#auth-confirm').value='';await enterApp();}catch(e){$('#auth-error').textContent=e.message;}finally{button.disabled=false;}};
async function enterApp(){await loadData();$('#auth').classList.add('hidden');$('#loading').classList.add('hidden');$('#app').classList.remove('hidden');renderUser();render();}
async function loadData(){const [expenses,budgets]=await Promise.all([api('/expenses'),api('/budgets')]);state.expenses=expenses;state.budgets=budgets;}
function renderUser(){$('#account-name').textContent=state.user.name;$('#avatar').textContent=state.user.name.charAt(0);$('#greeting').textContent=`أهلًا يا ${state.user.name.split(' ')[0]} 👋`;}
$('#logout').onclick=async()=>{try{await api('/logout','POST',{});reset();showAuth();mode(false);toast('تم تسجيل الخروج. نشوفك على خير.');}catch(e){toast(e.message,true);}};
$('#month-filter').value=localDate().slice(0,7);$('#month-filter').onchange=()=>{if(!/^\d{4}-\d{2}$/.test($('#month-filter').value))$('#month-filter').value=localDate().slice(0,7);render();};
$('#today').textContent=new Date().toLocaleDateString('ar-EG',{weekday:'long',day:'numeric',month:'long'});
for(const [key,[label]] of Object.entries(categories)){for(const selector of ['#expense-category','#category-filter']){const option=document.createElement('option');option.value=key;option.textContent=label;$(selector).append(option);}}
$('#category-filter').onchange=render;$('#search').oninput=render;
document.querySelectorAll('[data-view]').forEach(button=>button.onclick=()=>{state.view=button.dataset.view;document.querySelectorAll('[data-view]').forEach(b=>b.classList.toggle('active',b===button));const overview=state.view==='overview';$('#insights').classList.toggle('hidden',!overview);$('#page-title').textContent=overview?'صورة أوضح لمصروفاتك':'كل مصروف، في مكانه';$('#breadcrumb').textContent=overview?'نظرة عامة':'المصروفات';$('#table-title').textContent=overview?'مصروفاتك الأخيرة':'سجل المصروفات';render();});
function render(){
 if(!state.user)return;
 const month=$('#month-filter').value;
 const monthly=state.expenses.filter(e=>e.expenseDate.startsWith(month));
 const total=monthly.reduce((s,e)=>s+e.amountCents,0),budget=state.budgets.find(b=>b.month===month)?.amount;
 $('#spent').textContent=money(total);$('#count-summary').textContent=`${monthly.length} عملية خلال ${monthLabel(month)}`;
 $('#budget-total').textContent=budget===undefined?'—':money(budget);$('#budget-open').textContent=budget===undefined?'تحديد الميزانية ←':'تعديل الميزانية ←';$('#remaining').textContent=budget===undefined?'—':money(budget-total);$('#budget-progress').style.width=budget>0?`${Math.min(100,total/budget*100)}%`:'0%';$('.balance').classList.toggle('over',budget!==undefined&&total>budget);$('#budget-hint').textContent=budget===undefined?'حدّد ميزانيتك وابدأ المتابعة':total>budget?`متجاوز الميزانية بـ ${money(total-budget)} جنيه`:budget>0?`استخدمت ${Math.round(total/budget*100)}% من ميزانيتك`:'ميزانيتك الحالية صفر جنيه';
 const search=$('#search').value.trim().toLowerCase(),cat=$('#category-filter').value;
 const filtered=monthly.filter(e=>(!cat||e.expenseCategory===cat)&&(!search||e.expenseNote.toLowerCase().includes(search)));
 $('#empty').classList.toggle('hidden',filtered.length!==0);$('.table-wrap').classList.toggle('hidden',filtered.length===0);
 $('#empty h3').textContent=monthly.length?'مفيش مصروفات مطابقة':'كل حاجة بتبدأ بأول خطوة';$('#empty p').textContent=monthly.length?'جرّب تغيّر البحث أو التصنيف.':'أضف أول مصروف ليك في الشهر ده.';
 $('#expense-list').innerHTML=filtered.map(e=>{const [label,icon]=categories[e.expenseCategory]||categories.Other;return `<tr><td><div class="expense-description"><span class="cat-icon">${icon}</span><div><strong>${esc(e.expenseNote||label)}</strong><small>مصروف شخصي</small></div></div></td><td><span class="category-badge">${label}</span></td><td class="expense-date">${esc(new Date(`${e.expenseDate}T12:00:00`).toLocaleDateString('ar-EG',{day:'numeric',month:'short'}))}</td><td class="expense-money" dir="ltr">${money(e.amountCents)} <span class="subtle">EGP</span></td><td><div class="row-actions"><button class="icon-button" data-edit="${e.id}" aria-label="تعديل المصروف"><svg><use href="#edit"/></svg></button><button class="icon-button" data-delete="${e.id}" aria-label="حذف المصروف"><svg><use href="#trash"/></svg></button></div></td></tr>`;}).join('');
 $('#table-footer').innerHTML=`<span>${filtered.length} مصروف</span><span>الإجمالي: ${money(filtered.reduce((s,e)=>s+e.amountCents,0))} جنيه</span>`;
 const totals=Object.entries(categories).map(([key,[label]])=>({label,total:monthly.filter(e=>e.expenseCategory===key).reduce((s,e)=>s+e.amountCents,0)})).filter(c=>c.total>0).sort((a,b)=>b.total-a.total);
 $('#category-chart').innerHTML=totals.length?totals.map(c=>`<div class="cat-row"><span>${c.label}</span><span class="track"><i data-width="${c.total/total*100}"></i></span><span class="cat-value">${money(c.total)}</span></div>`).join(''):'<p class="chart-empty">أضف مصروفاتك وشوف توزيعها هنا.</p>';
 document.querySelectorAll('[data-width]').forEach(el=>el.style.width=`${el.dataset.width}%`);
 const weeks=[0,1,2,3].map(i=>monthly.filter(e=>Math.min(3,Math.floor((Number(e.expenseDate.slice(-2))-1)/7))===i).reduce((s,e)=>s+e.amountCents,0));const max=Math.max(...weeks,1);
 $('#weekly-chart').innerHTML=weeks.map((value,i)=>`<div class="week ${value===max?'highlight':''}"><span class="week-value">${value?money(value):'—'}</span><div class="week-column" data-height="${Math.max(3,value/max*120)}"></div><small>${['1–7','8–14','15–21','22–نهاية'][i]}</small></div>`).join('');document.querySelectorAll('[data-height]').forEach(el=>el.style.height=`${el.dataset.height}px`);
}
function openExpense(expense=null){state.editing=expense?.id??null;$('#expense-title').textContent=expense?'تعديل المصروف':'إضافة مصروف';$('#expense-amount').value=expense?(expense.amountCents/100).toFixed(2):'';$('#expense-category').value=expense?.expenseCategory||'Food';$('#expense-date').value=expense?.expenseDate||localDate();$('#expense-note').value=expense?.expenseNote||'';$('#expense-error').textContent='';$('#expense-dialog').showModal();}
$('#add-expense').onclick=()=>openExpense();$('#empty-add').onclick=()=>openExpense();
$('#expense-list').onclick=event=>{const edit=event.target.closest('[data-edit]'),del=event.target.closest('[data-delete]');if(edit)openExpense(state.expenses.find(e=>e.id===Number(edit.dataset.edit)));if(del){state.deleting=Number(del.dataset.delete);$('#delete-dialog').showModal();}};
$('#expense-form').onsubmit=async event=>{event.preventDefault();const button=event.submitter;button.disabled=true;$('#expense-error').textContent='';try{const data={amount:Math.round(Number($('#expense-amount').value)*100),category:$('#expense-category').value,date:$('#expense-date').value,note:$('#expense-note').value.trim()};await api(state.editing?`/expenses/${state.editing}`:'/expenses',state.editing?'PUT':'POST',data);await loadData();render();$('#expense-dialog').close();toast('تم حفظ المصروف. خطوة في مكانها!');}catch(e){$('#expense-error').textContent=e.message;}finally{button.disabled=false;}};
$('#delete-confirm').onclick=async()=>{const button=$('#delete-confirm');button.disabled=true;try{await api(`/expenses/${state.deleting}`,'DELETE');await loadData();render();$('#delete-dialog').close();toast('تم حذف المصروف.');}catch(e){toast(e.message,true);}finally{button.disabled=false;}};
$('#budget-open').onclick=()=>{const month=$('#month-filter').value;$('#budget-month-label').textContent=monthLabel(month);const budget=state.budgets.find(b=>b.month===month);$('#budget-input').value=budget?(budget.amount/100).toFixed(2):'';$('#budget-error').textContent='';$('#budget-dialog').showModal();};
$('#budget-form').onsubmit=async event=>{event.preventDefault();event.submitter.disabled=true;try{await api('/budget','PUT',{month:$('#month-filter').value,budget:Math.round(Number($('#budget-input').value)*100)});await loadData();render();$('#budget-dialog').close();toast('الميزانية اتحدّثت.');}catch(e){$('#budget-error').textContent=e.message;}finally{event.submitter.disabled=false;}};
$('#settings-open').onclick=()=>{$('#settings-name').value=state.user.name;$('#settings-email').value=state.user.email;$('#settings-error').textContent='';$('#settings-dialog').showModal();};
$('#settings-form').onsubmit=async event=>{event.preventDefault();event.submitter.disabled=true;try{const name=$('#settings-name').value.trim();await api('/profile','PUT',{displayName:name});state.user.name=name;renderUser();$('#settings-dialog').close();toast('تم تحديث اسمك.');}catch(e){$('#settings-error').textContent=e.message;}finally{event.submitter.disabled=false;}};
document.querySelectorAll('[data-close]').forEach(b=>b.onclick=()=>b.closest('dialog').close());
(async()=>{try{const data=await api('/me');state.user=data.user;state.csrf=data.csrf;await enterApp();}catch(e){reset();showAuth();if(e.message!=='سجّل الدخول علشان تكمّل.')$('#auth-error').textContent=e.message;}})();

// Totals are calculated by Haskell; ignore stale responses after a month switch.
let summaryVersion=0;
const originalRender=render;
render=function(){originalRender();if(!state.user)return;const version=++summaryVersion;const selected=$('#month-filter').value;api(`/summary?month=${encodeURIComponent(selected)}`).then(summary=>{if(version!==summaryVersion||!state.user)return;$('#spent').textContent=money(summary.total);$('#budget-total').textContent=summary.budget===null?'—':money(summary.budget);$('#remaining').textContent=summary.remaining===null?'—':money(summary.remaining);}).catch(e=>{if(version===summaryVersion&&state.user)toast(e.message,true);});};
