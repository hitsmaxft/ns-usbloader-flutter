/* SPDX-License-Identifier: GPL-3.0-or-later
 * Adapted from NS-USBloader by Dmitry Isaenko (2019-2020).
 * No JNI. This submits a trigger; it cannot establish that a console booted.
 */
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#ifdef _WIN32
#include <windows.h>
#include <setupapi.h>
#include <stdlib.h>
#define API __declspec(dllexport)
static const GUID usb_guid={0xa5dcbf10,0x6530,0x11d2,{0x90,0x1f,0x00,0xc0,0x4f,0xb9,0x51,0xed}};
/* libusb-win32 driver request. WinUSB does not support this oversized request. */
#define GET_STATUS_IOCTL CTL_CODE(FILE_DEVICE_UNKNOWN,0x807,METHOD_BUFFERED,FILE_ANY_ACCESS)
API int ns_windows_rcm_path(char *output,int capacity) {
  HDEVINFO devices=SetupDiGetClassDevsA(&usb_guid,NULL,NULL,DIGCF_DEVICEINTERFACE|DIGCF_PRESENT);
  if(devices==INVALID_HANDLE_VALUE) return -1;
  int count=0, result=-2;
  for(DWORD i=0;;i++) {
    SP_DEVICE_INTERFACE_DATA item={0}; item.cbSize=sizeof(item);
    if(!SetupDiEnumDeviceInterfaces(devices,NULL,&usb_guid,i,&item)) break;
    DWORD length=0;
    SetupDiGetDeviceInterfaceDetailA(devices,&item,NULL,0,&length,NULL);
    PSP_DEVICE_INTERFACE_DETAIL_DATA_A detail=calloc(1,length);
    if(!detail) {result=-3;break;}
    detail->cbSize=sizeof(*detail);
    SP_DEVINFO_DATA info={0};info.cbSize=sizeof(info);
    if(SetupDiGetDeviceInterfaceDetailA(devices,&item,detail,length,NULL,&info)) {
      char lower[4096]; snprintf(lower,sizeof(lower),"%s",detail->DevicePath);
      CharLowerBuffA(lower,(DWORD)strlen(lower));
      if(strstr(lower,"vid_0955&pid_7321")) {
        count++;
        char service[256]={0};
        SetupDiGetDeviceRegistryPropertyA(devices,&info,SPDRP_SERVICE,NULL,(PBYTE)service,sizeof(service),NULL);
        if(_stricmp(service,"libusb0")!=0 && _stricmp(service,"libusbK")!=0) result=-4;
        else if((int)strlen(detail->DevicePath)>=capacity) result=-5;
        else {strcpy(output,detail->DevicePath);result=0;}
      }
    }
    free(detail);
  }
  SetupDiDestroyDeviceInfoList(devices);
  return count>1?-6:result; /* Never pick the first of multiple RCM devices. */
}
API int ns_windows_rcm_trigger(const char *path) {
  char current[4096];
  int ready=ns_windows_rcm_path(current,sizeof(current));
  if(ready!=0 || strcmp(path,current)!=0) return ready!=0?ready:-7;
  HANDLE device=CreateFileA(path,GENERIC_READ|GENERIC_WRITE,FILE_SHARE_READ|FILE_SHARE_WRITE,NULL,OPEN_EXISTING,FILE_FLAG_OVERLAPPED,NULL);
  if(device==INVALID_HANDLE_VALUE) return -8;
  uint32_t request[6]={1000,2,0,0,0,0};
  unsigned char output[0x7000]={0};
  OVERLAPPED op={0}; op.hEvent=CreateEventA(NULL,TRUE,FALSE,NULL);
  if(!op.hEvent) {CloseHandle(device);return -9;}
  DWORD transferred=0;
  BOOL ok=DeviceIoControl(device,GET_STATUS_IOCTL,request,sizeof(request),output,sizeof(output),&transferred,&op);
  int result=0;
  if(!ok && GetLastError()!=ERROR_IO_PENDING) result=-(int)GetLastError();
  else if(!ok) {
    if(WaitForSingleObject(op.hEvent,1500)!=WAIT_OBJECT_0) CancelIoEx(device,&op);
    /* Drain cancellation before the stack buffers go out of scope. */
    if(!GetOverlappedResult(device,&op,&transferred,TRUE)) result=-(int)GetLastError();
  }
  CloseHandle(op.hEvent);CloseHandle(device);return result;
}
#else
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <linux/usbdevice_fs.h>
#define API __attribute__((visibility("default")))
API int ns_linux_rcm_trigger(int bus,int address) {
  if(bus<0 || bus>255 || address<1 || address>127) return -EINVAL;
  char path[64];snprintf(path,sizeof(path),"/dev/bus/usb/%03d/%03d",bus,address);
  int fd=open(path,O_RDWR|O_CLOEXEC);if(fd<0) return -errno;
  unsigned char buffer[8+0x7000]={0x82,0,0,0,0,0,0,0x70};
  struct usbdevfs_urb urb={0};
  urb.type=USBDEVFS_URB_TYPE_CONTROL;urb.endpoint=0x80;
  urb.buffer=buffer;urb.buffer_length=sizeof(buffer);
  int result=ioctl(fd,USBDEVFS_SUBMITURB,&urb);
  if(result<0) {result=-errno;close(fd);return result;}
  void *completed=NULL;
  for(int i=0;i<150;i++) {
    result=ioctl(fd,USBDEVFS_REAPURBNDELAY,&completed);
    if(result==0 || errno!=EAGAIN) break;
    usleep(10000);
  }
  if(result<0) {
    int saved=errno;
    ioctl(fd,USBDEVFS_DISCARDURB,&urb);
    /* Closing usbfs synchronously destroys pending URBs before freeing buffer. */
    close(fd);return -saved;
  }
  result=urb.status;close(fd);return result;
}
#endif
