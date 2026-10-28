#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Whole-operation watchdog, including preparation and closed-image evidence.

The Windows job contains only this runner and its descendants. A single timer
terminates the job at the deadline; this never queries process progress.
"""
import ctypes as C
import json
import os
import threading
import time


class Lifetime:
    def __init__(self, seconds, out):
        if os.name!='nt' or type(seconds) is not int or not 60<=seconds<=10800:
            raise ValueError('Windows whole-operation deadline60..10800 required')
        self.deadline=time.monotonic()+seconds;self.out=out
        k=self.k=C.WinDLL('kernel32',use_last_error=True)
        class Basic(C.Structure):
            _fields_=[('process_time',C.c_int64),('job_time',C.c_int64),('flags',C.c_uint32),
                ('min_working',C.c_size_t),('max_working',C.c_size_t),('active',C.c_uint32),
                ('affinity',C.c_size_t),('priority',C.c_uint32),('scheduling',C.c_uint32)]
        class IO(C.Structure):
            _fields_=[('values',C.c_uint64*6)]
        class Extended(C.Structure):
            _fields_=[('basic',Basic),('io',IO),('process_memory',C.c_size_t),('job_memory',C.c_size_t),
                ('peak_process',C.c_size_t),('peak_job',C.c_size_t)]
        self.Extended=Extended
        k.CreateJobObjectW.argtypes=[C.c_void_p,C.c_wchar_p];k.CreateJobObjectW.restype=C.c_void_p
        k.SetInformationJobObject.argtypes=[C.c_void_p,C.c_int,C.c_void_p,C.c_uint32]
        k.AssignProcessToJobObject.argtypes=[C.c_void_p,C.c_void_p]
        k.GetCurrentProcess.restype=C.c_void_p
        k.TerminateJobObject.argtypes=[C.c_void_p,C.c_uint32]
        k.CloseHandle.argtypes=[C.c_void_p]
        self.job=k.CreateJobObjectW(None,None)
        info=Extended();info.basic.flags=0x2000 # JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
        if not self.job or not k.SetInformationJobObject(self.job,9,C.byref(info),C.sizeof(info)):
            raise C.WinError(C.get_last_error())
        if not k.AssignProcessToJobObject(self.job,k.GetCurrentProcess()):
            k.CloseHandle(self.job);raise C.WinError(C.get_last_error())
        self.timer=threading.Timer(seconds,self.expire);self.timer.daemon=True;self.timer.start()

    def expire(self):
        # Reserved tiny failure output, even if the guest filled its envelope.
        try:
            if self.out.is_dir():
                data=(json.dumps(dict(status='WHOLE_OPERATION_TIMEOUT',limit_seconds=10800,
                    includes_logs_and_screenshots=True))+'\n').encode()
                with (self.out/'failure.json').open('xb') as output:output.write(data)
        finally:self.k.TerminateJobObject(self.job,124)

    def guest_seconds(self, requested):
        # Keep five minutes for exit, map, Panther, hashes and final receipt.
        available=int(self.deadline-time.monotonic())-300
        if available<1:raise ValueError('Insufficient whole-operation evidence reserve')
        return min(requested,available)

    def close(self):
        self.timer.cancel()
        info=self.Extended() # normal completion: do not kill this runner
        if not self.k.SetInformationJobObject(self.job,9,C.byref(info),C.sizeof(info)):
            raise C.WinError(C.get_last_error())
        self.k.CloseHandle(self.job)
