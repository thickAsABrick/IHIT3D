subroutine restart_read

  use m_openmpi
  use m_parameters
  use m_io
  use m_fields
  use m_work
  use x_fftw
  use m_particles
  implicit none

  integer*4    :: nx1,ny1,nz1, nums1, MST1, nums_read
  integer      :: i, j, k, n

  real*8 :: ST

  fname = run_name//'.64.'//file_ext
  inquire(file=fname,exist=there)
  if(.not.there) then
     write(out,*) '*** error: Cannot find file : '//trim(fname)
     stop
  end if

  write(out,*) 'Reading from the file (seq): ',trim(fname)
  call flush(out)

  ! root process reads parameters from the file
  if (myid_world.eq.0) then
     open(91,file=fname,form='unformatted',access='stream')
     read(91) nx1, ny1, nz1, nums1, MST1, TIME, DT
  end if

  call MPI_BCAST(nx1,  1,MPI_INTEGER4,0,MPI_COMM_WORLD,mpi_err)
  call MPI_BCAST(ny1,  1,MPI_INTEGER4,0,MPI_COMM_WORLD,mpi_err)
  call MPI_BCAST(nz1,  1,MPI_INTEGER4,0,MPI_COMM_WORLD,mpi_err)
  call MPI_BCAST(nums1,1,MPI_INTEGER4,0,MPI_COMM_WORLD,mpi_err)

  call MPI_BCAST(TIME,1,MPI_REAL8,0,MPI_COMM_WORLD,mpi_err)
  call MPI_BCAST(  DT,1,MPI_REAL8,0,MPI_COMM_WORLD,mpi_err)

  ! everyone checks of the parameters coinside with what's in the .in file
  if (nx.ne.nx1 .or. ny.ne.ny1 .or. nz_all.ne.nz1) then
     write(out,*) '*** error: Dimensions are different'
     write(out,*) '***     .in file: ',nx,ny,nz_all
     write(out,*) '*** restart file: ',nx1,ny1,nz1
     call flush(out)
     stop
  end if

!-----------------------------------------------------------------------
!     dealing with scalars.
!     
!     The number of scalars can be varied throughout the simulation.
!     If the restart file has fewer scalars than the 
!     .in file, the scalars are added and initialized according to
!     their description in the .in-file.  
!     If the restart file has more scalars than the .in file, the
!     extra scalars are dropped.
!     
!     in short, whatever is specfied in the .in file, prevails.
!-----------------------------------------------------------------------

  if (n_scalars.lt.nums1) then

     write(out,*) ' WARNING: nums in restart file:',nums1
     write(out,*) '          nums in .in file    :',n_scalars
     write(out,'(''Losing '',i3,'' scalars.'')') nums1-n_scalars
     call flush(out)
     nums_read = n_scalars

  else if (n_scalars.gt.nums1) then

     write(out,*) ' WARNING: nums in restart file:',nums1
     write(out,*) '          nums in .in file    :',n_scalars
     write(out,'(''Adding '',i3,'' scalars.'')') n_scalars-nums1
     call flush(out)
     nums_read = nums1

!!$       ! initializing the added scalars
!!$       if (int_scalars) then
!!$          do n=nums1+1,n_scalars
!!$             call ranfldsc(ms1(n),wm0sc1(n),ISCTYPE(n),esceng1(n),n)
!!$          end do
!!$       end if

  else

     nums_read = n_scalars

  end if

!----------------------------------------------------------------------
!  ------------ reading the stuff from the restart file ---------------
!----------------------------------------------------------------------

  ! only the hydro part of processors is involved in this
  hydro_only: if (task.eq.'hydro') then

     count = (nx+2) * ny * nz

     ! the root reads everything and sends to the slaves
     if (myid.eq.0) then

        do n = 1, 3 + nums_read + n_les

           ! first chunk belongs to the root
           read(91) (((fields(i,j,k,n),i=1,nx),j=1,ny),k=1,nz)

           ! the rest gets read and sent to the appropriate porcess
           do id_to = 1,numprocs-1
              read(91) (((wrk(i,j,k,1),i=1,nx),j=1,ny),k=1,nz)
              tag = (3+nums_read) * id_to + n-1
              call MPI_SEND(wrk(1,1,1,1),count,MPI_REAL8,id_to,tag,MPI_COMM_TASK,mpi_err)

!!$              write(out,'(''Sent variable '',i3,'' to '',i4,'': '',i2)') n,id_to,mpi_err
!!$              write(out,*) wrk(1:10,1,1,1)
!!$              call flush(out)

           end do

        end do

        ! then the root closes the restart file
        close(91)

     else
        ! the slaves receive and put it into ss array

        do n = 1, 3 + nums_read + n_les

           tag = (3+nums_read) * myid + n-1
           call MPI_RECV(fields(1,1,1,n),count,MPI_REAL8,0,tag,MPI_COMM_TASK,mpi_status,mpi_err)

        end do

     end if

  end if hydro_only

  return
end subroutine restart_read




!================================================================================
!================================================================================
!================================================================================
subroutine restart_write

!  This routine is called to GENERATE RESTART FILES  
!  The file is written without MPI-2 tricks
!  the stuff gets sent to the root process adn written out in
!  some orderly fashion

  use m_openmpi
  use m_parameters
  use m_io
  use m_fields
  use m_work
  use x_fftw
  implicit none

  integer :: n, nums_out, i, j, k

  real*8 :: ST
  integer :: MST

  if (itime.eq.last_dump) return


!---------------------------------------------------------------------
!     dumping the restart file with particles
!---------------------------------------------------------------------
!  if (int_particles) call particles_restart_write
!  if (int_particles) call particles_restart_write_binary



  ! how many scalars to write
  nums_out = 0
  if (int_scalars) nums_out = n_scalars

  ! first FFT everything to real space
  wrk(:,:,:,1:3+nums_out+n_les) = fields(:,:,:,1:3+nums_out+n_les)

!!$!^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
!!$  write(out,*) 'LEGACY CODE COMPATIBILITY: u,v,w <-> w,v,u'
!!$  call flush(out)
!!$  wrk(:,:,:,1) = fields(:,:,:,3)
!!$  wrk(:,:,:,2) = fields(:,:,:,2)
!!$  wrk(:,:,:,3) = fields(:,:,:,1)
!!$!^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
!  do n = 1,3+nums_out
!     call xFFT3d(-1,n)
!  end do

  ! --------------- writing process ------------------

  fname = run_name//'.64.'//file_ext

  ! if not the root, just send the stuff to the root
  if (myid.ne.0) then

     do n = 1 , 3 + nums_out + n_les

        wrk(:,:,:,0) = wrk(:,:,:,n)
        tag = (3+nums_out+n_les) * myid + n-1
        count = (nx+2) * ny * nz
        call MPI_ISEND(wrk(1,1,1,0),count,MPI_REAL8,0,tag,MPI_COMM_TASK,request,mpi_err)

!        write(out,'(''sending var '',i3,'' to '',i4,'': '',i3)') n,0,mpi_err
!        call flush(out)

        call MPI_WAIT(request,mpi_status,mpi_err)

!        write(out,'(''sent var '',i3,'' to '',i4,'': '',i3)') n,0,mpi_err
!        call flush(out)

     end do

  else
     ! if it's the root, then write the restart file
!!     open(91,file=fname,form='binary')
     open(91,file=fname,form='unformatted', access='stream')

     ! first write the parameters
     ST = zip
     write(91) int(nx,4),int(ny,4),int(nz*numprocs,4),int(nums_out,4),int(MST,4),TIME,DT

     ! then write the variables, one by one
     do n = 1 , 3 + nums_out + n_les

        ! first write the chunk from the root process
        wrk(:,:,:,0) = wrk(:,:,:,n)
        write(91) (((wrk(i,j,k,0),i=1,nx),j=1,ny),k=1,nz)
        ! then receive chinks of the same variable from each process and write it out
        do id_from=1,numprocs-1
           tag = (3+nums_out+n_les) * id_from + n-1
           count = (nx+2) * ny * nz
           call MPI_RECV(wrk(1,1,1,0),count,MPI_REAL8,id_from,tag,MPI_COMM_TASK,mpi_status,mpi_err)

!           write(out,'(''received var '',i3,'' from '',i4,'': '',i3)') n,id_from,mpi_err
!           call flush(out)

           write(91) (((wrk(i,j,k,0),i=1,nx),j=1,ny),k=1,nz)
        end do
     end do
     close(91)

  end if

  write(out,*) '------------------------------------------------'
  write(out,*) 'Restart file written (seq): '//trim(fname)
  write(out,"(' Velocities and ',i3,' scalars (incl. LES)')") nums_out+n_les
  write(out,"(' Restart file time = ',f15.10,i7)") time,itime
  write(out,*) '------------------------------------------------'
  call flush(out)


  ! setting the variable last_dump to current timestep number 
  last_dump = ITIME

  return
end subroutine restart_write


!================================================================================
!================================================================================
!================================================================================
subroutine restart_write_parallel

!  This routine is called to GENERATE RESTART FILES  
!  The file is written using the collective write (MPI-2 standard)

  use m_openmpi
  use m_parameters
  use m_io
  use m_fields
  use m_work
  use x_fftw
  implicit none

  integer :: n, nums_out, i, j, k

  integer :: MST
  integer(kind=MPI_INTEGER_KIND) :: fh
  integer(kind=MPI_OFFSET_KIND)  :: offset
  real*8, allocatable :: sctmp8(:,:,:)

  integer*4 :: nx1, ny1, nz1, nums1, MST1
  real*8 :: ST

  if (itime.eq.last_dump) return


  ! how many scalars to write
  nums_out = 0
  if (int_scalars) nums_out = n_scalars

  ! first FFT everything to real space
  wrk(:,:,:,1:3+nums_out+n_les) = fields(:,:,:,1:3+nums_out+n_les)


  ! Converting all variables to X-space (decided not to)
!  do n = 1,3+nums_out
!     call xFFT3d(-1,n)
!  end do

  ! --------------- writing process ------------------

  fname = run_name//'.64.'//file_ext

  ! allocating the temporary array sctmp8
  allocate(sctmp8(nx,ny,nz),stat=ierr)
  if (ierr.ne.0) stop '*** RESTART_READ_PARALLEL: cannot allocate sctmp8'
  sctmp8 = zip

  ! opening the file
  call MPI_INFO_CREATE(mpi_info, mpi_err)
  call MPI_FILE_OPEN(MPI_COMM_TASK,fname,MPI_MODE_WRONLY+MPI_MODE_CREATE,mpi_info,fh,mpi_err)

  ! the master node writes the header with parameters
  if (myid.eq.0) then
     nx1 = nx;  ny1 = ny;  nz1 = nz_all;  MST1 = 0;  nums1 = n_scalars; 
     count = 1
     ST = zip
     call MPI_FILE_WRITE(fh,   nx1, count, MPI_INTEGER4, mpi_status, mpi_err)
     call MPI_FILE_WRITE(fh,   ny1, count, MPI_INTEGER4, mpi_status, mpi_err)
     call MPI_FILE_WRITE(fh,   nz1, count, MPI_INTEGER4, mpi_status, mpi_err)
     call MPI_FILE_WRITE(fh, nums1, count, MPI_INTEGER4, mpi_status, mpi_err)
     call MPI_FILE_WRITE(fh,  MST1, count, MPI_INTEGER4, mpi_status, mpi_err)
     call MPI_FILE_WRITE(fh,  TIME, count, MPI_REAL8, mpi_status, mpi_err)
     call MPI_FILE_WRITE(fh,    DT, count, MPI_REAL8, mpi_status, mpi_err)
  end if

  ! all nodes write their stuff into the file
  writing_fields: do n = 1, 3 + nums_out + n_les

     offset = 36 + (n-1)*nx*ny*nz_all*8 + myid*nx*ny*nz*8
     count = nx * ny * nz
     ! note that we want the data from the restart to have dimensions (nx,ny,nz),
     ! while the fields array has fimensions (nx+2,ny,nz).
     ! this is an artefact of the times when the code used to write the variables in real space.
     ! that is why we need to duplicate each field in the sctmp array first, and then
     ! write sctmp8 into the file with appropriate offset

     sctmp8(1:nx,1:ny,1:nz) = wrk(1:nx,1:ny,1:nz,n)

     call MPI_FILE_WRITE_AT(fh, offset, sctmp8, count, MPI_REAL8, mpi_status, mpi_err)

  end do writing_fields

  call MPI_FILE_CLOSE(fh, mpi_err)
  call MPI_INFO_FREE(mpi_info, mpi_err)
  deallocate(sctmp8)

  write(out,*) '------------------------------------------------'
  write(out,*) 'Restart file written (par): '//trim(fname)
  write(out,"(' Velocities and ',i3,' scalars (including LES)')") nums_out+n_les
  write(out,"(' Restart file time = ',f15.10,i7)") time,itime
  write(out,*) '------------------------------------------------'
  call flush(out)


  last_dump = ITIME

  return
end subroutine restart_write_parallel

!================================================================================
!================================================================================
!================================================================================
!================================================================================

subroutine restart_read_parallel

  use m_openmpi
  use m_parameters
  use m_io
  use m_fields
  use m_work
  use x_fftw
  use m_particles
  implicit none

  integer*4    :: nx1,ny1,nz1, nums1, MST1, nums_read
  integer      :: i, j, k, n

  real*8 :: ST
  integer(kind=MPI_INTEGER_KIND) :: fh
  integer(kind=MPI_OFFSET_KIND)  :: offset
  real*8, allocatable :: sctmp8(:,:,:)

  ! checking if the restart file exists
  fname = run_name//'.64.'//file_ext
  inquire(file=fname,exist=there)
  if(.not.there) then
     write(out,*) '*** error: Cannot find file : '//trim(fname)
     stop
  end if

  write(out,*) 'Reading from the file (par): ',trim(fname)
  call flush(out)

  ! ----------------------------------------------------------------------
  ! first reading the parameters from the restart file.
  ! the root process opens it and reads the parameters, then broadcasts 
  ! the parameters.  After that it's decided if the parameters make sense,
  ! how many scalars to read etc.
  ! ----------------------------------------------------------------------

  if (myid.eq.0) then
!!     open(91,file=fname,form='binary')
     open(91,file=fname,form='unformatted',access='stream')
     read(91) nx1, ny1, nz1, nums1, MST1, TIME, DT
     close(91)
  end if

  call MPI_BCAST(nx1,  1,MPI_INTEGER4,0,MPI_COMM_TASK,mpi_err)
  call MPI_BCAST(ny1,  1,MPI_INTEGER4,0,MPI_COMM_TASK,mpi_err)
  call MPI_BCAST(nz1,  1,MPI_INTEGER4,0,MPI_COMM_TASK,mpi_err)
  call MPI_BCAST(nums1,1,MPI_INTEGER4,0,MPI_COMM_TASK,mpi_err)

  call MPI_BCAST(TIME,1,MPI_REAL8,0,MPI_COMM_TASK,mpi_err)
  call MPI_BCAST(  DT,1,MPI_REAL8,0,MPI_COMM_TASK,mpi_err)

  ! everyone checks of the parameters coinside with what's in the .in file
  if (nx.ne.nx1 .or. ny.ne.ny1 .or. nz_all.ne.nz1) then
     write(out,*) '*** error: Dimensions are different'
     write(out,*) '***     .in file: ',nx,ny,nz_all
     write(out,*) '*** restart file: ',nx1,ny1,nz1
     call flush(out)
     stop
  end if

!-----------------------------------------------------------------------
!     dealing with scalars.
!     
!     The number of scalars can be varied throughout the simulation.
!     If the restart file has fewer scalars than the 
!     .in file, the scalars are added and initialized according to
!     their description in the .in-file.  
!     If the restart file has more scalars than the .in file, the
!     extra scalars are dropped.
!     
!     in short, whatever is specfied in the .in file, prevails.
!-----------------------------------------------------------------------

  if (n_scalars.lt.nums1) then

     write(out,*) ' WARNING: nums in restart file:',nums1
     write(out,*) '          nums in .in file    :',n_scalars
     write(out,'(''Losing '',i3,'' scalars.'')') nums1-n_scalars
     call flush(out)
     nums_read = n_scalars

  else if (n_scalars.gt.nums1) then

     write(out,*) ' WARNING: nums in restart file:',nums1
     write(out,*) '          nums in .in file    :',n_scalars
     write(out,'(''Adding '',i3,'' scalars.'')') n_scalars-nums1
     call flush(out)
     nums_read = nums1

     ! initializing the added scalars
     do n=nums1+1,n_scalars
        call init_scalar(n)
     end do

  else

     nums_read = n_scalars

  end if

!----------------------------------------------------------------------
!  ------------ reading the stuff from the restart file ---------------
!----------------------------------------------------------------------

  ! allocating the temporary array sctmp8
  allocate(sctmp8(nx,ny,nz),stat=ierr)
  if (ierr.ne.0) stop '*** RESTART_READ_PARALLEL: cannot allocate sctmp8'
  sctmp8 = zip

  ! opening the file
  call MPI_INFO_CREATE(mpi_info, mpi_err)
  call MPI_FILE_OPEN(MPI_COMM_TASK,fname,MPI_MODE_RDONLY,mpi_info,fh,mpi_err)

  reading_fields: do n = 1, 3 + nums_read + n_les

     offset = 36 + (n-1)*nx*ny*nz_all*8 + myid*nx*ny*nz*8
     count = nx * ny * nz
     ! note that the data from the restart file has dimensions (nx,ny,nz),
     ! while the fields array has fimensions (nx+2,ny,nz).  
     ! that is why we need to read each field in the sctmp array first, and then
     ! rearrange it and put into the fields array.
!     call MPI_FILE_READ_AT(fh, offset, sctmp8, count, MPI_REAL8, mpi_status, mpi_err)
     call MPI_FILE_READ_AT_ALL(fh, offset, sctmp8, count, MPI_REAL8, mpi_status, mpi_err)

     fields(1:nx,1:ny,1:nz,n) = sctmp8(1:nx,1:ny,1:nz)

  end do reading_fields

  call MPI_FILE_CLOSE(fh, mpi_err)
  call MPI_INFO_FREE(mpi_info, mpi_err)
  deallocate(sctmp8)

!----------------------------------------------------------------------
!  FFT to the complex space and putting variables in fields array
!----------------------------------------------------------------------
!  fft_fields: do n = 1,3+nums_read
!     wrk(:,:,:,1) = fields(:,:,:,n)
!     call xFFT3d(1,1)
!     fields(:,:,:,n) = wrk(:,:,:,1)
!  end do fft_fields

  write(out,*) "Restart file successfully read."
  call flush(out)

  return
end subroutine restart_read_parallel
