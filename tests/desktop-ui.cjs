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
  child = spawn(exe, [], {stdio:'ignore',env:{...env,WEBVIEW2_USER_DATA_FOLDER:profile,
    WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS:'--remote-debugging-address=127.0.0.1 --remote-debugging-port=0'}})
  const deadline = Date.now()+45000
  let port
  while (!port && child.exitCode===null && Date.now()<deadline) {
    for (const sub of ['', 'EBWebView']) {
      const portFile = path.join(profile,sub,'DevToolsActivePort')
      if (fs.existsSync(portFile)) port = Number(fs.readFileSync(portFile,'utf8').split(/\r?\n/)[0])
    }
    if (!port) await delay(250)
  }
  assert.ok(port,'No test WebView2 endpoint')
  const browser=await chromium.connectOverCDP('http://127.0.0.1:'+port)
  while (!page && Date.now()<deadline) {
    page=browser.contexts().flatMap(c=>c.pages()).find(p=>/^https?:\/\/tauri\.localhost\//.test(p.url()))
    if (!page) await delay(250)
  }
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
run().catch(err=>{console.error(err.message);process.exitCode=1}).finally(()=>{
  if (child && child.exitCode===null) child.kill()
})
