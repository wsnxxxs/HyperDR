//! Process-tree ownership for the desktop sidecar.
//!
//! PyInstaller's one-file launcher can create a second process for the actual
//! Python runtime. A normal `Child::kill()` (and the shell plugin's equivalent)
//! only targets the launcher, so Windows gets a Job Object as the primary
//! ownership boundary and `taskkill /T /F` as a compatibility fallback.

#[cfg(not(windows))]
#[derive(Debug, Default)]
pub struct ProcessTree;

#[cfg(not(windows))]
impl ProcessTree {
    pub fn attach(_pid: u32) -> Self {
        Self
    }

    pub fn terminate(&self) {}
}

#[cfg(windows)]
mod windows_impl {
    use std::io;
    use std::mem::size_of;
    use std::process::Command;
    use std::ptr::null;

    use windows_sys::Win32::Foundation::{CloseHandle, GetLastError, HANDLE};
    use windows_sys::Win32::System::JobObjects::{
        AssignProcessToJobObject, CreateJobObjectW, JobObjectExtendedLimitInformation,
        SetInformationJobObject, TerminateJobObject, JOBOBJECT_EXTENDED_LIMIT_INFORMATION,
        JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
    };
    use windows_sys::Win32::System::Threading::{
        OpenProcess, PROCESS_QUERY_LIMITED_INFORMATION, PROCESS_SET_QUOTA, PROCESS_TERMINATE,
    };

    const CREATE_NO_WINDOW: u32 = 0x0800_0000;

    fn win_error(operation: &str) -> io::Error {
        let code = unsafe { GetLastError() };
        io::Error::new(
            io::ErrorKind::Other,
            format!("{operation} failed with Windows error {code}"),
        )
    }

    #[derive(Debug)]
    struct Job(HANDLE);

    // A Windows kernel handle is process-global and can safely be closed from
    // whichever Rust thread owns the ProcessTree state.
    unsafe impl Send for Job {}
    unsafe impl Sync for Job {}

    impl Job {
        fn attach(pid: u32) -> io::Result<Self> {
            let handle = unsafe { CreateJobObjectW(null(), null()) };
            if handle.is_null() {
                return Err(win_error("CreateJobObjectW"));
            }

            let mut limits = JOBOBJECT_EXTENDED_LIMIT_INFORMATION::default();
            limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
            let configured = unsafe {
                SetInformationJobObject(
                    handle,
                    JobObjectExtendedLimitInformation,
                    (&limits as *const JOBOBJECT_EXTENDED_LIMIT_INFORMATION).cast(),
                    size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>() as u32,
                )
            };
            if configured == 0 {
                unsafe { CloseHandle(handle) };
                return Err(win_error("SetInformationJobObject"));
            }

            let process = unsafe {
                OpenProcess(
                    PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_SET_QUOTA | PROCESS_TERMINATE,
                    0,
                    pid,
                )
            };
            if process.is_null() {
                unsafe { CloseHandle(handle) };
                return Err(win_error("OpenProcess"));
            }

            let assigned = unsafe { AssignProcessToJobObject(handle, process) };
            unsafe { CloseHandle(process) };
            if assigned == 0 {
                unsafe { CloseHandle(handle) };
                return Err(win_error("AssignProcessToJobObject"));
            }

            Ok(Self(handle))
        }

        fn terminate(&self) {
            let _ = unsafe { TerminateJobObject(self.0, 1) };
        }
    }

    impl Drop for Job {
        fn drop(&mut self) {
            unsafe { CloseHandle(self.0) };
        }
    }

    #[derive(Debug)]
    pub struct ProcessTree {
        pid: u32,
        job: Option<Job>,
    }

    impl ProcessTree {
        pub fn attach(pid: u32) -> Self {
            let job = match Job::attach(pid) {
                Ok(job) => Some(job),
                Err(error) => {
                    eprintln!("Unable to attach HyperDR sidecar to a Windows Job Object: {error}");
                    None
                }
            };
            Self { pid, job }
        }

        pub fn terminate(&self) {
            if let Some(job) = &self.job {
                job.terminate();
            }

            // This also catches descendants created in the small interval
            // between CreateProcess and AssignProcessToJobObject, and covers
            // machines where nested Job Objects are refused by the OS.
            let pid = self.pid.to_string();
            let mut command = Command::new("taskkill");
            command.args(["/PID", &pid, "/T", "/F"]);
            use std::os::windows::process::CommandExt;
            command.creation_flags(CREATE_NO_WINDOW);
            let _ = command.status();
        }
    }
}

#[cfg(windows)]
pub use windows_impl::ProcessTree;
