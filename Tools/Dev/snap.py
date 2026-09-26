import subprocess,time,sys
S=sys.argv[1]; shots=[(n,float(t)) for n,t in (a.split('@') for a in sys.argv[2:])]
t=time.time(); wid=''
while not wid and time.time()-t<45:
    wid=subprocess.run([S+'/winid'],capture_output=True,text=True).stdout.strip(); time.sleep(0.05)
t=time.time()
for name,at in shots:
    time.sleep(max(0,at-(time.time()-t)))
    subprocess.run(['screencapture','-x','-o','-l',wid,f'{S}/shot-{name}.png'])
    subprocess.run(['sips','-Z','1000',f'{S}/shot-{name}.png','--out',f'{S}/small-{name}.png'],capture_output=True)
print('window',wid or 'NONE')
