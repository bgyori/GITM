! Copyright 2021, the GITM Development Team (see srcDoc/dev_team.md for members)
! Full license can be found in LICENSE

subroutine calc_ion_v(iBlock)

  use ModGITM
  use ModInputs
  use ModConstants

  implicit none

  integer, intent(in) :: iBlock
  integer :: iLon, iLat, iAlt, iIon, iSpecies
  integer :: imax, jmax, kmax, iError, iDir
  real    :: maxi, TanLat

  real, dimension(-1:nLons+2,-1:nLats+2,-1:nAlts+2) ::           &
                  B02, ForceDotB, Nie, RhoNu, IRho, &
                  VIParallel, VNParallel, gDotB, gpDotB, UDotB, &
                  LocalGravity, ViDotB

  real, dimension(-1:nLons+2, -1:nLats+2, -1:nAlts+2, 3) ::           &
                  Force, BLocal, & 
                  ForceCrossB, ForcePerp, &
                  LocalPressureGradient, &
                  LocalNeutralWinds, IVelGradient

  real, dimension(-1:nLons+2, -1:nLats+2, -1:nAlts+2):: Pressure_G, nu_in
  
  !---------------------------------------------------------------------------

  call report("Ion Forcing Terms",1)
  call start_timing("Ion Forcing")

  IVelocity(:,:,:,:,iBlock) = 0.0

  if (iDebugLevel > 4) write(*,*) "=====> pressure gradient", iproc

  ! Pressure is the sum of ion and electron pressure The electron
  ! pressure is included here because of the electron momentum
  ! equation: When all terms multipled by the electron mass are
  ! ignored, you get grad(Pe) = E-par, When you put E-par into ion
  ! momentum eqn, you can simply add grad(Pe) to grad(Pi).
  
  Pressure_G = IPressure(:,:,:,iBlock) + ePressure(:,:,:,iBlock)
  call UAM_Gradient_GC(Pressure_G, LocalPressureGradient, iBlock)

  ! We store this for output to files:
  IonPressureGradient(:,:,:,:,iBlock) = LocalPressureGradient

  ! In 1D, we are not going to use the horizontal pressure gradient:
  if (Is1D) then
     LocalPressureGradient(:,:,:,iEast_) = 0.0
     LocalPressureGradient(:,:,:,iNorth_) = 0.0
  endif

  ! If the user doesn't want to use the pressure gradient, set it to zero:
  if (.not.useIonPressureGradient) LocalPressureGradient = 0.0

  ! If the user doesn't want to use gravity, then set it to zero:
  if (UseIonGravity) then
     LocalGravity = Gravity_GB(:,:,:,iBlock)
  else
     LocalGravity = 0.0
  endif

  if (UseNeutralDrag) then 
     LocalNeutralWinds = Velocity(:,:,:,:,iBlock)
  else
     LocalNeutralWinds = 0.0
  endif
  
  Force = 0.0

  IRho = IDensityS(:,:,:,ie_,iBlock) * &
       MeanIonMass(:,:,:)

  do iAlt = -1, nAlts+2
     Force(:,:,iAlt,iUp_) = Force(:,:,iAlt,iUp_) + &
          IRho(:,:,iAlt) * LocalGravity(:,:,iAlt)
  enddo

  Nie = IDensityS(:,:,:,ie_,iBlock) * Element_Charge

  BLocal = B0(:,:,:,1:3,iBlock)
  B02 = B0(:,:,:,iMag_,iBlock)**2

  if (UseExB) then
     do iDir = 1, 3
        Force(:,:,:,iDir) = Force(:,:,:,iDir) + &
             Nie * EField(:,:,:,iDir)
     enddo
  endif

  ! Generalize Rho * Nu:
  RhoNu = 0.0
  do iIon = 1, nIonsAdvect
     do iSpecies = 1, nSpecies
        RhoNu = RhoNu + &
             IDensityS(:,:,:,iIon,iBlock) * MassI(iIon) * &
             IonCollisions(:,:,:,iIon,iSpecies)
     enddo
  enddo

  nu_in = RhoNu / iRho
  
  if (UseNeutralDrag) then
     do iDir = 1, 3
        Force(:,:,:,iDir) = Force(:,:,:,iDir) + &
             RhoNu * LocalNeutralWinds(:,:,:,iDir)
     enddo
  endif

  ForceDotB = sum(Force * BLocal, dim=4)

  do iDir = 1, 3
     ForcePerp(:,:,:,iDir) = Force(:,:,:,iDir) - &
          ForceDotB(:,:,:) * B0(:,:,:,iDir,iBlock) / &
          B0(:,:,:,iMag_,iBlock)**2
  enddo

  VIParallel = 0.0
  VNParallel = 0.0

  if (maxval(blocal) == 0) then

     IVelocity(:,:,:,iUp_,iBlock) = &
          LocalNeutralWinds(:,:,:,iUp_) + &
          (LocalGravity(:,:,:)*iRho - &
          LocalPressureGradient(:,:,:,iUp_)) / &
          RhoNu

     IVelocity(:,:,:,iEast_,iBlock) = &
          LocalNeutralWinds(:,:,:,iEast_) - &
          LocalPressureGradient(:,:,:,iEast_) / RhoNu

     IVelocity(:,:,:,iNorth_,iBlock) = &
          LocalNeutralWinds(:,:,:,iNorth_) - &
          LocalPressureGradient(:,:,:,iNorth_) / RhoNu
         
  else

     UDotB = sum(LocalNeutralWinds(:,:,:,:) * BLocal, dim=4)/ &
          B0(:,:,:,iMag_,iBlock)
     gpDotB = sum(LocalPressureGradient(:,:,:,:) * &
          BLocal, dim=4) / B0(:,:,:,iMag_,iBlock)

     do iLon = -1,nLons+2
        do iLat = -1,nLats+2
           gDotB(iLon,iLat,:) = LocalGravity(iLon, iLat, :) &
                * BLocal(iLon,iLat,:,iUp_) &
                /     B0(iLon,iLat,:,iMag_,iBlock)
        enddo
     enddo

     if (UseImplicitFieldAlignedMomentum) then

        VIParallel = dt/(1+nu_in) * &
             (-gpDotB / IRho + gDotB + nu_in * UDotB + &
             VIParallel/dt)

     else

        VIParallel = UDotB + ( gDotB*iRho - gpDotB ) / RhoNu

     endif

     ! Let's limit the Parallel Flow to something reasonable...

     VIParallel = min( UDotB + MaxVParallel, VIParallel)
     VIParallel = max( UDotB - MaxVParallel, VIParallel)

     ForceCrossB(:,:,:,iEast_) = &
          Force(:,:,:,iNorth_) * BLocal(:,:,:,iUp_) - &
          Force(:,:,:,iUp_)    * BLocal(:,:,:,iNorth_)

     ForceCrossB(:,:,:,iNorth_) = &
          Force(:,:,:,iUp_)    * BLocal(:,:,:,iEast_) - &
          Force(:,:,:,iEast_)  * BLocal(:,:,:,iUp_)

     ForceCrossB(:,:,:,iUp_)    = &
          Force(:,:,:,iEast_)  * BLocal(:,:,:,iNorth_) - &
          Force(:,:,:,iNorth_) * BLocal(:,:,:,iEast_)

     do iDir = 1, 3

        IVelocityPar(:,:,:,iDir, iBlock) = &
             VIParallel*BLocal(:,:,:,iDir)/&
             B0(:,:,:,iMag_,iBlock)

        IVelocityPar(:, :, iAlt+1, iDir, iBlock) = &
             IVelocityPar(:, :, iAlt, iDir, iBlock)
        IVelocityPar(:, :, iAlt+2, iDir, iBlock) = &
             IVelocityPar(:, :, iAlt, iDir, iBlock)
        
        IVelocityPerp(:,:,:,iDir, iBlock) = &
             ( RhoNu * ForcePerp(:,:,:,iDir) &
             + Nie * ForceCrossB(:,:,:,iDir) &
             ) / (RhoNu**2 + Nie**2 * B02)

        IVelocity(:,:,:,iDir, iBlock) = &
             IVelocityPar(:,:,:,iDir, iBlock) + &
             IVelocityPerp(:,:,:,iDir, iBlock)
             
     enddo

  endif

  IVelocity(:,:,:,:,iBlock) = min( 3000.0, IVelocity(:,:,:,:,iBlock))
  IVelocity(:,:,:,:,iBlock) = max(-3000.0, IVelocity(:,:,:,:,iBlock))

  call end_timing("Ion Forcing")

  if (iDebugLevel > 4) write(*,*) "=====> done with calc_ion_v", iproc

end subroutine calc_ion_v
