const {execFileSync}=require('node:child_process');
const fs=require('node:fs');const path=require('node:path');
const root=path.resolve(__dirname,'..');
execFileSync('cargo',['+stable','build','--manifest-path',path.join(root,'native/Cargo.toml'),'--release'],{stdio:'inherit',env:{...process.env,...(process.env.ORT_DYLIB_PATH?{QRK_EMBED_RUNTIME:process.env.ORT_DYLIB_PATH}:{})}});
const filename=process.platform==='win32'?'qrk_node.dll':process.platform==='darwin'?'libqrk_node.dylib':'libqrk_node.so';
const dir=path.join(root,'prebuilds',`${process.platform}-${process.arch}`);fs.mkdirSync(dir,{recursive:true});
const addon=path.join(dir,'qrk.node');if(fs.existsSync(addon))fs.unlinkSync(addon);fs.copyFileSync(path.join(root,'native/target/release',filename),addon);
if(process.platform==='darwin')execFileSync('/usr/bin/codesign',['--force','--sign','-','--timestamp=none',addon]);
if(process.env.ORT_DYLIB_PATH){const target=process.platform==='win32'?'onnxruntime.dll':process.platform==='darwin'?'libonnxruntime.dylib':'libonnxruntime.so';const dest=path.join(dir,target);if(fs.existsSync(dest))fs.unlinkSync(dest);fs.copyFileSync(process.env.ORT_DYLIB_PATH,dest);if(process.platform==='darwin')execFileSync('/usr/bin/codesign',['--force','--sign','-','--timestamp=none',dest]);}

for(const name of ["LICENSE","THIRD_PARTY_NOTICES.md"]){fs.copyFileSync(path.join(root,"../..",name),path.join(dir,name));}
fs.cpSync(path.join(root,"../../third-party"),path.join(dir,"third-party"),{recursive:true});
