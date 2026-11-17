"""Integration tests against a fresh, isolated SQLite database (standard library only)."""
import json, os, pathlib, subprocess, tempfile, time, urllib.request, urllib.error, http.cookiejar
ROOT=pathlib.Path(__file__).resolve().parents[1]
EXE=ROOT/'dist-newstyle/build/x86_64-windows/ghc-9.10.3/masroufy-0.1.0.0/x/masroufy/build/masroufy/masroufy.exe'
BASE='http://127.0.0.1:3099'
class Client:
 def __init__(self):
  self.jar=http.cookiejar.CookieJar();self.opener=urllib.request.build_opener(urllib.request.HTTPCookieProcessor(self.jar));self.csrf=''
 def request(self,path,method='GET',body=None,csrf=True,marker=True):
  headers={'Content-Type':'application/json'}
  if marker:headers['X-Requested-With']='Masroufy'
  if csrf:headers['X-CSRF-Token']=self.csrf
  req=urllib.request.Request(BASE+'/api'+path,data=None if body is None else json.dumps(body).encode(),headers=headers,method=method)
  try:
   with self.opener.open(req) as r: return r.status,json.load(r)
  except urllib.error.HTTPError as e:return e.code,json.load(e)
 def signup(self,email):
  status,data=self.request('/signup','POST',{'name':'Test User','email':email,'password':'Test password 123!'})
  assert status==201,(status,data);self.csrf=data['csrf'];return data

def check(condition,message):
 assert condition,message
 print('PASS:',message)

with tempfile.TemporaryDirectory(prefix='masroufy-test-') as tmp:
 env=os.environ.copy();env['DATABASE_PATH']=str(pathlib.Path(tmp)/'test.sqlite');env['PORT']='3099'
 proc=subprocess.Popen([str(EXE)],cwd=ROOT,env=env,stdout=None,stderr=None)
 try:
  guest=Client()
  for _ in range(100):
   try:
    if guest.request('/health')[0]==200:break
   except OSError:time.sleep(.1)
  else:raise RuntimeError('Test server did not start')
  with urllib.request.urlopen(BASE+'/') as page:
   check(page.headers.get_content_type()=='text/html','Home page served as HTML')
  check(guest.request('/expenses')[0]==401,'Unauthenticated access denied')
  a,b=Client(),Client();a.signup('alice@example.com');b.signup('bob@example.com')
  check(a.request('/me')[1]['user']['email']=='alice@example.com','Session identifies correct owner')
  check(a.request('/signup','POST',{'name':'Other','email':'ALICE@example.com','password':'Test password 123!'})[0]==409,'Email uniqueness is case insensitive')
  check(guest.request('/login','POST',{'email':'alice@example.com','password':'wrong password'})[0]==401,'Incorrect password rejected')
  check(guest.request('/login','POST',{'email':'alice@example.com','password':'Test password 123!'},marker=False)[0]==403,'Cross-origin form-style authentication rejected')
  expense={'amount':15050,'category':'Food','date':'2026-11-17','note':'Lunch'}
  check(a.request('/expenses','POST',expense,csrf=False)[0]==403,'Missing CSRF token rejected')
  status,new=a.request('/expenses','POST',expense);check(status==201, f'Expense created: {status} {new}');eid=new['id']
  check(len(a.request('/expenses')[1])==1,'Owner sees expense')
  check(b.request('/expenses')[1]==[],'Other user cannot list owner expenses')
  check(b.request(f'/expenses/{eid}','PUT',{**expense,'amount':1})[0]==404,'Other user cannot edit by guessing ID')
  check(b.request(f'/expenses/{eid}','DELETE')[0]==404,'Other user cannot delete by guessing ID')
  check(a.request(f'/expenses/{eid}','PUT',{**expense,'amount':20025})[0]==200,'Owner can edit expense')
  check(a.request('/expenses','POST',{**expense,'amount':0})[0]==400,'Zero expense rejected')
  check(a.request('/expenses','POST',{**expense,'date':'2026-02-30'})[0]==400,'Impossible date rejected')
  check(a.request('/expenses','POST',{**expense,'category':'Invalid'})[0]==400,'Unknown category rejected')
  check(a.request('/budget','PUT',{'month':'2026-11','budget':500000})[0]==200,'Monthly budget saved')
  check(b.request('/budgets')[1]==[],'Budgets isolated between accounts')
  summary=a.request('/summary?month=2026-11')[1]
  check(summary['total']==20025 and summary['remaining']==479975,'Haskell calculates exact totals in integer cents')
  check(a.request('/summary?month=2026-12')[1]['total']==0,'Month filtering is correct')
  check(a.request('/profile','PUT',{'displayName':'New Name'})[0]==200,'Profile updated')
  check(a.request('/me')[1]['user']['name']=='New Name','Profile update persisted')
  check(a.request('/logout','POST',{})[0]==200 and a.request('/me')[0]==401,'Logout invalidates session')
  status,data=a.request('/login','POST',{'email':'alice@example.com','password':'Test password 123!'});a.csrf=data['csrf']
  check(status==200 and len(a.request('/expenses')[1])==1,'Login restores persistent data')
  check(a.request(f'/expenses/{eid}','DELETE')[0]==200 and a.request('/expenses')[1]==[],'Owner can delete expense')
  import sqlite3
  with sqlite3.connect(env['DATABASE_PATH']) as db:
   salt,digest=db.execute('SELECT salt,password_hash FROM users LIMIT 1').fetchone()
   check('Test password' not in digest and len(digest)==64 and len(salt)==64,'Only salted password digests are stored')
  db.close()
  # A separate client IP shares the same local limiter: all 30 attempts count by IP, not source port.
  for _ in range(35): code,_=guest.request('/login','POST',{'email':'nobody@example.com','password':'incorrect password'})
  check(code==429,'Authentication rate limit enforced')
  print('\nAll integration tests passed.')
 finally:
  proc.terminate();proc.wait(timeout=10)




