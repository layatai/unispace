use std::{ffi::OsStr, fs::{self, File, Metadata}, os::unix::fs::{FileExt, MetadataExt}, path::PathBuf,
    sync::{Arc, Mutex, atomic::{AtomicU64, Ordering}}, time::{Duration, UNIX_EPOCH}};
use fuser::{Config, Errno, FileAttr, FileHandle, FileType, Filesystem, FopenFlags, Generation, INodeNo,
    LockOwner, MountOption, OpenFlags, ReplyAttr, ReplyData, ReplyDirectory, ReplyEntry, ReplyOpen, Request};
use serde::Serialize;

const MAX_READ: usize = 256 * 1024;
#[derive(Clone)]
struct Entry { path: PathBuf, name: String, meta: Metadata, ino: u64 }
fn stamp(value: &Metadata) -> (u64,u64,u64,i64,i64,i64,i64) {
    (value.dev(),value.ino(),value.len(),value.mtime(),value.mtime_nsec(),value.ctime(),value.ctime_nsec())
}
#[derive(Default)]
struct Counters { metadata: AtomicU64, opens: AtomicU64, reads: AtomicU64, bytes: AtomicU64, writer: Mutex<()> }
#[derive(Serialize)]
struct Report { metadata_calls: u64, opens: u64, read_calls: u64, content_bytes: u64 }
struct LazyFs { entries: Vec<Entry>, state: PathBuf, counts: Arc<Counters>, uid: u32, gid: u32 }
impl LazyFs {
    fn save(&self) {
        let _guard = self.counts.writer.lock().unwrap();
        let report = Report { metadata_calls:self.counts.metadata.load(Ordering::SeqCst),opens:self.counts.opens.load(Ordering::SeqCst),
            read_calls:self.counts.reads.load(Ordering::SeqCst),content_bytes:self.counts.bytes.load(Ordering::SeqCst) };
        let tmp=self.state.with_extension("tmp");
        if let Ok(data)=serde_json::to_vec_pretty(&report) { if fs::write(&tmp,data).is_ok() {let _=fs::rename(tmp,&self.state);} }
    }
    fn attr(&self, id: u64) -> Option<FileAttr> {
        let file=self.entries.iter().find(|entry|entry.ino==id);
        if id!=1 && file.is_none() {return None;}
        Some(FileAttr { ino:INodeNo(id),size:file.map_or(0,|entry|entry.meta.len()),blocks:0,
            atime:UNIX_EPOCH,mtime:UNIX_EPOCH,ctime:UNIX_EPOCH,crtime:UNIX_EPOCH,
            kind:if id==1 {FileType::Directory} else {FileType::RegularFile},perm:if id==1 {0o700} else {0o400},
            nlink:if id==1 {2} else {1},uid:self.uid,gid:self.gid,rdev:0,flags:0,blksize:4096 })
    }
}
impl Filesystem for LazyFs {
    fn lookup(&self,_:&Request,parent:INodeNo,name:&OsStr,reply:ReplyEntry) {
        self.counts.metadata.fetch_add(1,Ordering::SeqCst);self.save();
        if u64::from(parent)!=1 {reply.error(Errno::ENOENT);return;}
        if let Some(entry)=self.entries.iter().find(|entry|OsStr::new(&entry.name)==name) {
            reply.entry(&Duration::from_secs(1),&self.attr(entry.ino).unwrap(),Generation(1));
        } else {reply.error(Errno::ENOENT);}
    }
    fn getattr(&self,_:&Request,ino:INodeNo,_:Option<FileHandle>,reply:ReplyAttr) {
        self.counts.metadata.fetch_add(1,Ordering::SeqCst);self.save();
        match self.attr(u64::from(ino)) {Some(value)=>reply.attr(&Duration::from_secs(1),&value),None=>reply.error(Errno::ENOENT)}
    }
    fn open(&self,_:&Request,ino:INodeNo,_:OpenFlags,reply:ReplyOpen) {
        if self.attr(u64::from(ino)).is_none() {reply.error(Errno::ENOENT);return;}
        self.counts.opens.fetch_add(1,Ordering::SeqCst);self.save();
        // Opening a virtual path never opens the source or reads contents.
        reply.opened(FileHandle(u64::from(ino)),FopenFlags::FOPEN_DIRECT_IO);
    }
    fn read(&self,_:&Request,ino:INodeNo,_:FileHandle,offset:u64,size:u32,_:OpenFlags,_:Option<LockOwner>,reply:ReplyData) {
        let Some(entry)=self.entries.iter().find(|entry|entry.ino==u64::from(ino)) else {reply.error(Errno::ENOENT);return;};
        if size as usize>MAX_READ {reply.error(Errno::EINVAL);return;}
        self.counts.reads.fetch_add(1,Ordering::SeqCst);
        let result=(||->std::io::Result<Vec<u8>> {
            let before=fs::symlink_metadata(&entry.path)?;
            if stamp(&before)!=stamp(&entry.meta) {return Err(std::io::Error::other("source changed"));}
            let length=(size as u64).min(entry.meta.len().saturating_sub(offset)) as usize;
            let mut bytes=vec![0;length];
            if length>0 {
                let source=File::open(&entry.path)?;
                if stamp(&source.metadata()?)!=stamp(&entry.meta) {return Err(std::io::Error::other("source changed"));}
                let count=source.read_at(&mut bytes,offset)?;
                if count!=length || stamp(&source.metadata()?)!=stamp(&entry.meta) {return Err(std::io::Error::other("source changed"));}
                self.counts.bytes.fetch_add(count as u64,Ordering::SeqCst);
            }
            Ok(bytes)
        })();
        self.save();
        match result {Ok(bytes)=>reply.data(&bytes),Err(_)=>reply.error(Errno::EIO)}
    }
    fn readdir(&self,_:&Request,ino:INodeNo,_:FileHandle,offset:u64,mut reply:ReplyDirectory) {
        self.counts.metadata.fetch_add(1,Ordering::SeqCst);self.save();
        if u64::from(ino)!=1 {reply.error(Errno::ENOENT);return;}
        let mut entries=vec![(1,FileType::Directory,".".to_string()),(1,FileType::Directory,"..".to_string())];
        entries.extend(self.entries.iter().map(|entry|(entry.ino,FileType::RegularFile,entry.name.clone())));
        for (index,(id,kind,name)) in entries.into_iter().enumerate().skip(offset as usize) {
            if reply.add(INodeNo(id),(index+1) as u64,kind,name) {break;}
        }
        reply.ok();
    }
}
fn main() -> Result<(),Box<dyn std::error::Error>> {
    let arguments:Vec<_>=std::env::args().collect();
    if arguments.len()!=4 {return Err("usage: probe <source-fixture-dir> <mount-dir> <state-json>".into());}
    let source=PathBuf::from(&arguments[1]);let mount=PathBuf::from(&arguments[2]);let state=PathBuf::from(&arguments[3]);
    fs::create_dir_all(&mount)?;
    let mut entries=Vec::new();
    for entry in fs::read_dir(source)? {
        let path=entry?.path();let meta=fs::symlink_metadata(&path)?;
        if !meta.file_type().is_file() {return Err("only regular generated fixtures are accepted".into());}
        let name=path.file_name().ok_or("filename missing")?.to_str().ok_or("invalid UTF-8")?.to_string();
        entries.push(Entry{path,name,meta,ino:0});
    }
    entries.sort_by(|a,b|a.name.cmp(&b.name));
    for (index,entry) in entries.iter_mut().enumerate() {entry.ino=index as u64+2;}
    let fs=LazyFs{entries,state,counts:Arc::new(Counters::default()),uid:unsafe{libc::getuid()},gid:unsafe{libc::getgid()}};
    fs.save();
    let mut config=Config::default();
    config.mount_options.extend([MountOption::RO,MountOption::DefaultPermissions,MountOption::FSName("unispace-lazy-qa".into()),MountOption::CUSTOM("max_read=262144".into())]);
    fuser::mount2(fs,&mount,&config)?;
    Ok(())
}
