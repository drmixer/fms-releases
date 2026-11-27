const {chromium} = require('playwright-core')
const {spawn, execFileSync} = require('node:child_process')
const fs = require('node:fs')
const path = require('node:path')
const {randomUUID} = require('node:crypto')
const assert = require('node:assert/strict')
const {setTimeout: delay} = require('node:timers/promises')
const env = process.env
if (process.platform !== 'win32' || env.GITHUB_REPOSITORY !== 'drmixer/fms-releases' ||
    env.RUNNER_ENVIRONMENT !== 'github-hosted' || env.FMS_PUBLIC_RUNNER_TEST !== '1') {
  throw Error('Requires the disposable Windows release runner.')
}
const exe = path.join(env.RUNNER_TEMP, 'FMS desktop test', 'fms.exe')
assert.equal(env.FMS_TEST_EXE.toLowerCase(), exe.toLowerCase())
const work = fs.mkdtempSync(path.join(env.RUNNER_TEMP, 'fms-ui-'))
const project = path.join(work, 'Project')
fs.mkdirSync(project)
const original = randomUUID()
const source = path.join(project, '.env')
fs.writeFileSync(source, 'RESEND_API_KEY=' + original + '\n')
function powershell(command) {
  return execFileSync('powershell.exe', ['-NoProfile','-NonInteractive','-Command',command],
    {encoding:'utf8',timeout:15000}).trim()
}
function startupValues() {
  const data = powershell("@([Microsoft.Win32.Registry]::CurrentUser,[Microsoft.Win32.Registry]::LocalMachine) | ForEach-Object { $key = $_.OpenSubKey('Software\\Microsoft\\Windows\\CurrentVersion\\Run'); if ($key) { $key.GetValue('FMS'); $key.Dispose() } }")
  return data.split(/\r?\n/).filter(Boolean)
}
function passed(text) { console.log('PASS: '+text) }
let child, page
async function launch() {
  // Isolate the debugging endpoint and WebView data to this throwaway app process.
  const profile = fs.mkdtempSync(path.join(work,'webview-'))
  const listener=require('node:net').createServer()
  await new Promise(resolve=>listener.listen(0,'127.0.0.1',resolve))
  const port=listener.address().port
  await new Promise(resolve=>listener.close(resolve))
  child = spawn(exe, [], {stdio:'ignore',env:{...env,WEBVIEW2_USER_DATA_FOLDER:profile,
    WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS:'--remote-debugging-address=127.0.0.1 --remote-debugging-port='+port}})
  const deadline = Date.now()+25000
  const endpoint='http://127.0.0.1:'+port
  let ready=false
  while (!ready && child.exitCode===null && Date.now()<deadline) {
    try { ready=(await fetch(endpoint+'/json/version',{signal:AbortSignal.timeout(1000)})).ok } catch {}
    if (!ready) await delay(200)
  }
  assert.ok(ready,'No test WebView2 endpoint on the assigned loopback port')
  const browser=await chromium.connectOverCDP(endpoint)
  while (!page && Date.now()<deadline) {
    page=browser.contexts().flatMap(c=>c.pages()).find(p=>/^https?:\/\/tauri\.localhost\//.test(p.url()))
    if (!page) await delay(250)
  }
  if (!page) console.log('WebView page origins:',browser.contexts().flatMap(c=>c.pages()).map(p=>new URL(p.url()).origin))
  assert.ok(page,'FMS page did not appear')
  page.setDefaultTimeout(15000)
  await page.getByRole('button',{name:'Settings',exact:true}).waitFor()
  await page.getByText('FMS v0.1.1',{exact:true}).waitFor()
}
const button = name => page.getByRole('button',{name,exact:true}).first()
async function quit() {
  const current=child
  if (!await button('Quit FMS').isVisible()) await button('Settings').click()
  await button('Quit FMS').click()
  const deadline=Date.now()+10000
  while (current.exitCode===null && Date.now()<deadline) await delay(200)
  assert.equal(current.exitCode,0,'Quit FMS should exit cleanly')
  page=undefined
}
async function run() {
  assert.equal(startupValues().length,0,'Expected a clean startup registration')
  await launch()
  await button('Add project manually').click()
  await page.getByLabel('Project name').fill('Desktop QA')
  await page.getByLabel(/Local folder/).fill(project)
  await button('Add project').click()
  await button('Manage project').waitFor()
  const search=page.getByRole('textbox',{name:'Search projects, services, accounts and identities'})
  await search.fill('RESEND_API_KEY')
  await button('Securely save').click()
  await button('Copy secret').waitFor()
  passed('Rendered project creation, credential discovery and Securely save')
  await quit()
  passed('Settings > Quit FMS exited normally')
  fs.writeFileSync(source,'RESEND_API_KEY='+randomUUID()+'\n')
  await launch()
  await page.getByRole('textbox',{name:'Search projects, services, accounts and identities'}).fill('RESEND_API_KEY')
  powershell("Set-Clipboard -Value 'fms-test-before-copy'")
  await button('Copy secret').click()
  await page.getByText('Secret copied to clipboard.',{exact:true}).waitFor()
  if (powershell('Get-Clipboard -Raw')!==original) throw Error('Copied value differed from synthetic saved value')
  powershell("Set-Clipboard -Value 'fms-test-complete'")
  passed('After restart, Copy secret returned the original synthetic value despite a changed source')
  await button('Settings').click()
  const login=page.getByRole('checkbox',{name:/Launch at login/i})
  await login.check()
  await page.getByText('FMS will launch quietly when you sign in.',{exact:true}).waitFor()
  const entries=startupValues()
  const safeCommand='"'+exe+'" --background'
  const exact=entries.length===1 && entries[0].toLowerCase()===safeCommand.toLowerCase()
  const unquoted=entries.length===1 && entries[0].toLowerCase()===(exe+' --background').toLowerCase()
  console.log('Registration count:',entries.length,'; executable and argument matched:',exact||unquoted,'; spaced path quoted:',exact)
  await login.uncheck()
  await page.getByText('Launch at login disabled.',{exact:true}).waitFor()
  assert.equal(startupValues().length,0,'Disabling launch at login should remove the entry')
  passed('Launch-at-login disable removed the registration')
  await quit()
  assert.ok(exact, 'Expected the installed path containing spaces to be quoted and followed by --background')
  passed('Launch-at-login registered the exact executable and background argument')
}
function dialog(title, action, value) {
  const args=['-NoProfile','-NonInteractive','-File',path.join(__dirname,'desktop-dialog.ps1'),
    '-AppId',String(child.pid),'-Title',title,'-Action',action]
  if (value) args.push('-Value',value)
  execFileSync('powershell.exe',args,{stdio:'inherit',timeout:25000})
}
async function account() {
  await button('+ Account').click()
  await page.getByLabel('Service',{exact:true}).fill('Resend')
  await page.getByLabel('Email / username').fill('desktop@example.invalid')
  await button('Save account').click()
  await page.getByText('Account saved locally.',{exact:false}).first().waitFor()
  passed('Added a synthetic account through the form')
}
async function scan() {
  const scanRoot=path.join(work,'Scan root')
  const folder=path.join(scanRoot,'qa-scan-project')
  fs.mkdirSync(folder,{recursive:true})
  fs.writeFileSync(path.join(folder,'package.json'),JSON.stringify({name:'qa-scan-project',dependencies:{resend:'1.0.0'}}))
  await button('Scan').click()
  dialog('Choose where your projects live','Select Folder',scanRoot)
  await button('Select all').click()
  await button('Import selected').click()
  const search=page.getByRole('textbox',{name:'Search projects, services, accounts and identities'})
  await search.fill('qa-scan-project')
  await button('Manage project').click()
  passed('Scanned a synthetic folder through the Windows picker and imported its project')
  const toolsRow=page.locator('.tool-detail-row').filter({hasText:'Resend'})
  await toolsRow.getByRole('button',{name:'Connect account'}).click()
  await page.getByRole('button',{name:/desktop@example\.invalid/i}).first().click()
  await toolsRow.getByRole('button',{name:'Manage account'}).waitFor()
  passed('Linked the existing account to the discovered Resend service')
  await button('Reveal').click()
  process.env.FMS_TEST_REVEAL=folder
  const revealed=powershell("$shell=New-Object -ComObject Shell.Application; for ($i=0; $i -lt 12; $i++) { foreach($w in $shell.Windows()) { try { foreach($item in $w.Document.SelectedItems()) { if ($item.Path -eq $env:FMS_TEST_REVEAL) { 'found'; return } } } catch {} }; Start-Sleep -Milliseconds 250 }")
  assert.equal(revealed,'found','Explorer should select the test project folder')
  passed('Reveal selected the imported project folder in Windows Explorer')
  powershell("(New-Object -ComObject WScript.Shell).SendKeys('^+f')")
  await page.getByRole('textbox',{name:'Quick Find',exact:true}).fill('desktop@example.invalid')
  await page.getByLabel('Quick Find results').getByText(/desktop@example\.invalid/i).first().waitFor()
  passed('Global Ctrl+Shift+F opened Quick Find and found the synthetic login')
}
async function backup() {
  const file=path.join(work,'QA metadata.json')
  await button('Settings').click()
  await button('Export backup').click()
  dialog('Export private FMS metadata','Save',file)
  await page.getByText(/Metadata backup saved/).first().waitFor()
  const raw=fs.readFileSync(file,'utf8')
  const data=JSON.parse(raw)
  assert.equal(data.format,'fms-metadata-backup')
  assert.ok(data.identities.some(i=>i.value==='desktop@example.invalid'),'Missing test account identity')
  const appData=path.join(env.APPDATA,'com.findmyshit.fms')
  assert.ok(fs.existsSync(path.join(appData,'fms.sqlite3')))
  passed('Exported a readable metadata backup containing the test identity')
  await quit()
  fs.renameSync(appData,path.join(work,'prior-app-data'))
  await launch()
  await button('Settings').click()
  await button('Restore backup').click()
  dialog('Restore FMS metadata','Open',file)
  dialog('Restore FMS metadata','Restore metadata')
  await page.getByText(/Metadata restored for/).first().waitFor()
  await quit()
  await launch()
  await page.getByRole('textbox',{name:'Search projects, services, accounts and identities'}).fill('desktop@example.invalid')
  await page.getByText(/desktop@example\.invalid/i).first().waitFor()
  passed('Restored the exported metadata into an empty app profile and found the account after restart')
}

async function extraFlows() {
  await launch()
  if (process.argv[2]==='account') await account()
  if (process.argv[2]==='scan') await scan()
  if (process.argv[2]==='backup') await backup()
  if (process.argv[2]!=='scan') await quit()
}
const test=process.argv[2] ? extraFlows : run
test().catch(err=>{console.error(err.message);process.exitCode=1}).finally(()=>{
  if (child && child.exitCode===null) child.kill()
})
