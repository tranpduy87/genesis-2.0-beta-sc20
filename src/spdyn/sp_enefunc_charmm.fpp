!--------1---------2---------3---------4---------5---------6---------7---------8
!
!  Module   sp_enefunc_charmm_mod
!> @brief   define potential energy functions
!! @authors Jaewoon Jung (JJ), Takeshi Imai (TI), Chigusa Kobayashi (CK),
!!          Takaharu Mori (TM), Yuji Sugita (YS)
!
!  (c) Copyright 2014 RIKEN. All rights reserved.
!
!--------1---------2---------3---------4---------5---------6---------7---------8

#ifdef HAVE_CONFIG_H
#include "../config.h"
#endif

module sp_enefunc_charmm_mod

  use sp_enefunc_localres_mod
  use sp_enefunc_restraints_mod
  use sp_enefunc_fit_mod
  use sp_enefunc_table_mod
  use sp_energy_mod
  use sp_restraints_str_mod
  use sp_constraints_str_mod
  use sp_enefunc_str_mod
  use sp_energy_str_mod
  use sp_domain_str_mod
  use dihedral_libs_mod
  use molecules_str_mod
  use fileio_par_mod
  use fileio_localres_mod
  use timers_mod
  use messages_mod
  use mpi_parallel_mod
  use constants_mod
#ifdef MPI
  use mpi
#endif

  implicit none
  private

  ! subroutines
  public  :: define_enefunc_charmm
  private :: setup_enefunc_bond
  private :: setup_enefunc_bond_constraint
  private :: setup_enefunc_angl
  private :: setup_enefunc_angl_constraint
  private :: setup_enefunc_dihe
  private :: setup_enefunc_impr
  private :: setup_enefunc_cmap
  private :: setup_enefunc_nonb
  public  :: count_nonb_excl

contains

  !======1=========2=========3=========4=========5=========6=========7=========8
  !
  !  Subroutine    define_enefunc_charmm
  !> @brief        a driver subroutine for defining potential energy functions
  !! @authors      YS, TI, JJ, CK
  !! @param[in]    ene_info    : ENERGY section control parameters information
  !! @param[in]    par         : CHARMM PAR information
  !! @param[in]    localres    : local restraint information
  !! @param[in]    molecule    : molecule information
  !! @param[inout] constraints : constraints information
  !! @param[in]    restraints  : restraints information
  !! @param[inout] domain      : domain information
  !! @param[inout] enefunc     : energy potential functions information
  !
  !======1=========2=========3=========4=========5=========6=========7=========8

  subroutine define_enefunc_charmm(ene_info, par, localres, molecule, &
                                   constraints, restraints, domain, enefunc)

    ! formal arguments
    type(s_ene_info),        intent(in)    :: ene_info
    type(s_par),             intent(in)    :: par
    type(s_localres),        intent(in)    :: localres
    type(s_molecule),        intent(in)    :: molecule
    type(s_constraints),     intent(inout) :: constraints
    type(s_restraints),      intent(in)    :: restraints
    type(s_domain),          intent(inout) :: domain
    type(s_enefunc),         intent(inout) :: enefunc

    ! local variables
    integer                  :: ncel, ncelb


    ! base
    !
    ncel  = domain%num_cell_local
    ncelb = domain%num_cell_local + domain%num_cell_boundary

    call alloc_enefunc(enefunc, EneFuncBase, ncel, ncel)
    call alloc_enefunc(enefunc, EneFuncBond, ncel, ncel)
    call alloc_enefunc(enefunc, EneFuncAngl, ncel, ncel)
    call alloc_enefunc(enefunc, EneFuncDihe, ncel, ncel)
    call alloc_enefunc(enefunc, EneFuncImpr, ncel, ncel)
    call alloc_enefunc(enefunc, EneFuncBondCell, ncel, ncelb)

    if (.not. constraints%rigid_bond) then

      ! bond
      !
      call setup_enefunc_bond(par, molecule, domain, enefunc)

      ! angle
      !
      call setup_enefunc_angl(par, molecule, domain, enefunc)

    else

      ! bond
      !
      call setup_enefunc_bond_constraint( &
                              par, molecule, domain, constraints, enefunc)

      ! angle
      !
      call setup_enefunc_angl_constraint( &
                              par, molecule, domain, constraints, enefunc)

    end if

    ! dihedral
    !
    call setup_enefunc_dihe(par, molecule, domain, enefunc)

    ! improper
    !
    call setup_enefunc_impr(par, molecule, domain, enefunc)

    ! cmap
    !
    call setup_enefunc_cmap(ene_info, par, molecule, domain, enefunc)

    ! nonbonded
    !
    call setup_enefunc_nonb(par, molecule, constraints, domain, enefunc)

    ! lookup table
    !
    if (ene_info%table) &
    call setup_enefunc_table(ene_info, enefunc)

    ! restraint
    !
    call setup_enefunc_restraints(molecule, restraints, domain, enefunc)

    call setup_enefunc_localres(localres, domain, enefunc)

    ! write summary of energy function
    !
    if (main_rank) then
      write(MsgOut,'(A)') &
           'Define_Enefunc_Charmm> Number of Interactions in Each Term'
      write(MsgOut,'(A20,I10,A20,I10)')                  &
           '  bond_ene        = ', enefunc%num_bond_all, &
           '  angle_ene       = ', enefunc%num_angl_all
      write(MsgOut,'(A20,I10,A20,I10)')                  &
           '  torsion_ene     = ', enefunc%num_dihe_all, &
           '  improper_ene    = ', enefunc%num_impr_all
      write(MsgOut,'(A20,I10)')                          &
           '  cmap_ene        = ', enefunc%num_cmap_all
      write(MsgOut,'(A20,I10,A20,I10)')                  &
           '  nb_exclusions   = ', enefunc%num_excl_all, &
           '  nb14_calc       = ', enefunc%num_nb14_all
      write(MsgOut,'(A)') ' '
    end if

    return

  end subroutine define_enefunc_charmm

  !======1=========2=========3=========4=========5=========6=========7=========8
  !
  !  Subroutine    setup_enefunc_bond
  !> @brief        define BOND term for each cell in potential energy function
  !! @authors      YS, JJ, TM
  !! @param[in]    par      : CHARMM PAR information
  !! @param[in]    molecule : molecule information
  !! @param[in]    domain   : domain information
  !! @param[inout] enefunc  : potential energy functions information
  !
  !======1=========2=========3=========4=========5=========6=========7=========8

  subroutine setup_enefunc_bond(par, molecule, domain, enefunc)

    ! formal arguments
    type(s_par),             intent(in)    :: par
    type(s_molecule),target, intent(in)    :: molecule
    type(s_domain),  target, intent(in)    :: domain
    type(s_enefunc), target, intent(inout) :: enefunc

    ! local variable
    integer                  :: dupl, ioffset
    integer                  :: i, j, icel_local
    integer                  :: icel1, icel2
    integer                  :: nbond, nbond_p, i1, i2, i3, found, found1
    character(6)             :: ci1, ci2, ci3, ri1, ri2

    real(wp),        pointer :: force(:,:), dist(:,:)
    integer,         pointer :: nwater(:), bond(:), list(:,:,:)
    integer,         pointer :: ncel
    integer(int2),   pointer :: cell_pair(:,:)
    integer(int2),   pointer :: id_g2l(:,:)
    integer,         pointer :: mol_bond_list(:,:), sollist(:)
    character(6),    pointer :: mol_cls_name(:)


    mol_bond_list => molecule%bond_list
    mol_cls_name  => molecule%atom_cls_name

    ncel      => domain%num_cell_local
    cell_pair => domain%cell_pair
    id_g2l    => domain%id_g2l
    nwater    => domain%num_water

    bond      => enefunc%num_bond
    list      => enefunc%bond_list
    force     => enefunc%bond_force_const
    dist      => enefunc%bond_dist_min
    sollist   => enefunc%table%solute_list_inv

    nbond     = molecule%num_bonds
    nbond_p   = par%num_bonds

    do dupl = 1, domain%num_duplicate

      ioffset = (dupl-1) * enefunc%table%num_solute

      do i = 1, nbond

        i1  = molecule%bond_list(1,i)
        i2  = molecule%bond_list(2,i)
        ci1 = mol_cls_name(i1)
        ci2 = mol_cls_name(i2)
        ri1 = molecule%residue_name(i1)
        ri2 = molecule%residue_name(i2)

        if (ri1(1:3) /= 'TIP' .and. ri1(1:3) /= 'WAT' .and. &
            ri1(1:3) /= 'SOL' .and. ri2(1:3) /= 'TIP' .and. &
            ri2(1:3) /= 'WAT' .and. ri2(1:3) /= 'SOL') then

          i1  = sollist(i1) + ioffset
          i2  = sollist(i2) + ioffset

          icel1 = id_g2l(1,i1)
          icel2 = id_g2l(1,i2)

          ! Check if it is in my domain
          !
          if (icel1 /= 0 .and. icel2 /= 0) then

            icel_local = cell_pair(icel1,icel2)

            if (icel_local > 0 .and. icel_local <= ncel) then

              do j = 1, nbond_p
                if ((ci1 == par%bond_atom_cls(1,j) .and.  &
                     ci2 == par%bond_atom_cls(2,j)) .or.  &
                    (ci1 == par%bond_atom_cls(2,j) .and.  &
                     ci2 == par%bond_atom_cls(1,j))) then
  
                  bond (icel_local) = bond(icel_local) + 1
                  list (1,bond(icel_local),icel_local) = i1
                  list (2,bond(icel_local),icel_local) = i2
                  force(bond(icel_local),icel_local)   = par%bond_force_const(j)
                  dist (bond(icel_local),icel_local)   = par%bond_dist_min(j)
                  exit
  
                end if
              end do

              if (j == nbond_p + 1) &
                write(MsgOut,*) &
                  'Setup_Enefunc_Bond> not found BOND: [', &
                  ci1, ']-[', ci2, '] in parameter file. (ERROR)'
  
            end if
  
          end if
 
        end if
 
      end do
    end do

    ! bond/angel from water
    !
    i1 = enefunc%table%water_list(1,1)
    i2 = enefunc%table%water_list(2,1)
    i3 = enefunc%table%water_list(3,1)
    ci1 = molecule%atom_cls_name(i1)
    ci2 = molecule%atom_cls_name(i2)
    ci3 = molecule%atom_cls_name(i3)
    do j = 1, nbond_p
      if ((ci1 == par%bond_atom_cls(1, j) .and.  &
           ci2 == par%bond_atom_cls(2, j)) .or.  &
          (ci1 == par%bond_atom_cls(2, j) .and.  &
           ci2 == par%bond_atom_cls(1, j))) then
        enefunc%table%OH_bond = par%bond_dist_min(j)
        enefunc%table%OH_force = par%bond_force_const(j)
        enefunc%table%water_bond_calc_OH = .true.
        exit
      end if
    end do
    do j = 1, nbond_p
      if ((ci2 == par%bond_atom_cls(1, j) .and.  &
           ci3 == par%bond_atom_cls(2, j)) .or.  &
          (ci2 == par%bond_atom_cls(2, j) .and.  &
           ci3 == par%bond_atom_cls(1, j))) then
        enefunc%table%HH_bond = par%bond_dist_min(j)
        enefunc%table%HH_force = par%bond_force_const(j)
        if (enefunc%table%HH_force > EPS) &
          enefunc%table%water_bond_calc_HH = .true.
        exit
      end if
    end do

    enefunc%table%water_bond_calc = .true.

    found  = 0
    found1 = 0
    do i = 1, ncel
      found = found + bond(i)
      if (enefunc%table%water_bond_calc_OH) found = found + 2*nwater(i)
      if (enefunc%table%water_bond_calc_HH) found = found + nwater(i)
      found1 = found1 + nwater(i)
      if (bond(i) > MaxBond) &
        call error_msg('Setup_Enefunc_Bond> Too many bonds.')
    end do

#ifdef MPI
    call mpi_allreduce(found, enefunc%num_bond_all, 1, mpi_integer, &
                       mpi_sum, mpi_comm_country, ierror)
    call mpi_allreduce(mpi_in_place, found1, 1, mpi_integer, &
                       mpi_sum, mpi_comm_country, ierror)
#else
    enefunc%num_bond_all = found
#endif

    if (enefunc%num_bond_all /= nbond*domain%num_duplicate .and. &
        enefunc%num_bond_all+found1 /= nbond*domain%num_duplicate) &
      call error_msg('Setup_Enefunc_Bond> Some bond paremeters are missing.')

    return

  end subroutine setup_enefunc_bond

  !======1=========2=========3=========4=========5=========6=========7=========8
  !
  !  Subroutine    setup_enefunc_bond_constraint
  !> @brief        define BOND term between heavy atoms
  !! @authors      JJ
  !! @param[in]    par         : CHARMM PAR information
  !! @param[in]    molecule    : molecule information
  !! @param[in]    domain      : domain information
  !! @param[inout] constraints : constraints information
  !! @param[inout] enefunc     : potential energy functions information
  !
  !======1=========2=========3=========4=========5=========6=========7=========8

  subroutine setup_enefunc_bond_constraint(par, molecule, domain, &
                                           constraints, enefunc)

    ! formal arguments
    type(s_par),                 intent(in)    :: par
    type(s_molecule),    target, intent(in)    :: molecule
    type(s_domain),      target, intent(in)    :: domain
    type(s_constraints), target, intent(inout) :: constraints
    type(s_enefunc),     target, intent(inout) :: enefunc

    ! local variable
    integer                      :: dupl, ioffset
    integer                      :: i, j, k, m, ih, icel_local, connect
    integer                      :: i1, i2, ih1, ih2, icel1, icel2, icel
    integer                      :: nbond, nbond_p, nbond_a, nbond_c
    integer                      :: wat_bonds, tmp_mole_no, mole_no, wat_found
    character(6)                 :: ci1, ci2
    character(6)                 :: ri1, ri2
    logical                      :: mi1, mi2
    logical                      :: cl1, cl2

    real(wp),            pointer :: force(:,:), dist(:,:)
    real(wip),           pointer :: HGr_bond_dist(:,:,:,:)
    integer,             pointer :: bond(:), list(:,:,:), num_water, ncel
    integer,             pointer :: id_l2g(:,:), id_l2g_sol(:,:), sollist(:)
    integer(int2),       pointer :: cell_pair(:,:)
    integer(int2),       pointer :: id_g2l(:,:)
    integer,             pointer :: HGr_local(:,:), HGr_bond_list(:,:,:,:)
    integer,             pointer :: mol_bond_list(:,:), mol_no(:)
    character(6),        pointer :: mol_cls_name(:), mol_res_name(:)
    logical,             pointer :: mol_light_name(:), mol_light_mass(:)


    mol_bond_list  => molecule%bond_list
    mol_no         => molecule%molecule_no
    mol_cls_name   => molecule%atom_cls_name
    mol_res_name   => molecule%residue_name
    mol_light_name => molecule%light_atom_name
    mol_light_mass => molecule%light_atom_mass

    ncel          => domain%num_cell_local
    cell_pair     => domain%cell_pair
    id_g2l        => domain%id_g2l
    id_l2g        => domain%id_l2g
    id_l2g_sol    => domain%id_l2g_solute

    HGr_local     => constraints%HGr_local
    HGr_bond_list => constraints%HGr_bond_list
    HGr_bond_dist => constraints%HGr_bond_dist

    bond          => enefunc%num_bond
    list          => enefunc%bond_list
    force         => enefunc%bond_force_const
    dist          => enefunc%bond_dist_min
    num_water     => enefunc%table%num_water
    sollist       => enefunc%table%solute_list_inv

    nbond         = molecule%num_bonds
    nbond_p       = par%num_bonds

    connect       =  constraints%connect

    nbond_a       = 0
    nbond_c       = 0

    do dupl = 1, domain%num_duplicate

      ioffset = (dupl-1) * enefunc%table%num_solute

      do i = 1, nbond

        i1  = mol_bond_list(1,i)
        i2  = mol_bond_list(2,i)

        ri1 = mol_res_name(i1)
        ri2 = mol_res_name(i2)

        if (ri1(1:3) /= 'TIP' .and. ri1(1:3) /= 'WAT' .and. &
            ri1(1:3) /= 'SOL' .and. ri2(1:3) /= 'TIP' .and. &
            ri2(1:3) /= 'WAT' .and. ri2(1:3) /= 'SOL') then

          ci1 = mol_cls_name(i1)
          ci2 = mol_cls_name(i2)
          mi1 = mol_light_mass(i1)
          mi2 = mol_light_mass(i2)
          cl1 = mol_light_name(i1)
          cl2 = mol_light_name(i2)
        
          if (constraints%hydrogen_type == ConstraintAtomMass) then
            cl1 = mi1 
            cl2 = mi2 
          else if (constraints%hydrogen_type == ConstraintAtomBoth) then
            cl1 = (cl1 .or. mi1) 
            cl2 = (cl2 .or. mi2) 
          endif
  
          i1  = sollist(i1) + ioffset
          i2  = sollist(i2) + ioffset
  
          if (.not. (cl1 .or.  cl2)) then
  
            icel1 = id_g2l(1,i1)
            icel2 = id_g2l(1,i2)
  
            ! Check if it is in my domain
            !
            if (icel1 /= 0 .and. icel2 /= 0) then
    
              icel_local = cell_pair(icel1,icel2)
    
              if (icel_local > 0 .and. icel_local <= ncel) then
  
                do j = 1, nbond_p
                  if ((ci1 == par%bond_atom_cls(1, j) .and.  &
                       ci2 == par%bond_atom_cls(2, j)) .or.  &
                      (ci1 == par%bond_atom_cls(2, j) .and.  &
                       ci2 == par%bond_atom_cls(1, j))) then
    
                    nbond_a = nbond_a + 1
                    bond (icel_local) = bond(icel_local) + 1
                    list (1,bond(icel_local),icel_local) = i1
                    list (2,bond(icel_local),icel_local) = i2
                    force(bond(icel_local),icel_local) = par%bond_force_const(j)
                    dist (bond(icel_local),icel_local) = par%bond_dist_min(j)
                    exit
    
                  end if
                end do
    
                if (j == nbond_p + 1) &
                  write(MsgOut,*) &
                    'Setup_Enefunc_Bond_Constraint> not found BOND: [', &
                    ci1, ']-[', ci2, '] in parameter file. (ERROR)'
    
              end if
    
            end if
    
          else
  
            icel1 = id_g2l(1,i1)
            icel2 = id_g2l(1,i2)
  
            if (icel1 /= 0 .and. icel2 /= 0) then
  
              icel = cell_pair(icel1,icel2)
              if (icel > 0 .and. icel <= ncel) then
  
                do j = 1, connect
  
                  do k = 1, HGr_local(j,icel)
                    ih1 = id_l2g_sol(HGr_bond_list(1,k,j,icel),icel)
                    do ih = 1, j
                      ih2 = id_l2g_sol(HGr_bond_list(ih+1,k,j,icel),icel)
    
                      if (ih1 == i1 .and. ih2 == i2 .or. &
                          ih2 == i1 .and. ih1 == i2) then
                      
                        do m = 1, nbond_p
                          if ((ci1 == par%bond_atom_cls(1, m) .and.  &
                               ci2 == par%bond_atom_cls(2, m)) .or.  &
                              (ci1 == par%bond_atom_cls(2, m) .and.  &
                               ci2 == par%bond_atom_cls(1, m))) then
      
                            nbond_c = nbond_c + 1
                            HGr_bond_dist(ih+1,k,j,icel) = par%bond_dist_min(m)
                            exit
                          end if
                        end do
    
                    end if
    
                    end do
                  end do
    
                end do
              end if
            end if
    
          end if
 
        end if
 
      end do
    end do

    ! for water molecule
    !
    wat_bonds = 0
    wat_found = 0

    if (constraints%fast_water) then

      tmp_mole_no = -1

      do i = 1, nbond

        i1 = mol_bond_list(1,i)
        i2 = mol_bond_list(2,i)
        ri1 = mol_res_name(i1)
        ri2 = mol_res_name(i2)

        if (ri1 == constraints%water_model .and. &
            ri2 == constraints%water_model) then

          wat_bonds=wat_bonds+1
          mole_no = mol_no(i1)

          if (mole_no /= tmp_mole_no) then
            wat_found = wat_found +1
            tmp_mole_no = mole_no
          end if

        end if

      end do

      if (wat_found /= num_water) &
        call error_msg( &
          'Setup_Enefunc_Bond_Constraint> # of water is incorrect')

    end if

#ifdef MPI
    call mpi_allreduce(nbond_a, enefunc%num_bond_all,  1, mpi_integer, &
                       mpi_sum, mpi_comm_country, ierror)

    call mpi_allreduce(nbond_c, constraints%num_bonds, 1, mpi_integer, &
                       mpi_sum, mpi_comm_country, ierror)
#else
    enefunc%num_bond_all  = nbond_a
    constraints%num_bonds = nbond_c
#endif

    if (constraints%fast_water) then

      if (enefunc%num_bond_all /= (nbond*domain%num_duplicate &
                                     -constraints%num_bonds     &
                                     -wat_bonds*domain%num_duplicate)) then
        call error_msg( &
          'Setup_Enefunc_Bond_Constraint> Some bond paremeters are missing.')
      end if

    end if

    return

  end subroutine setup_enefunc_bond_constraint

  !======1=========2=========3=========4=========5=========6=========7=========8
  !
  !  Subroutine    setup_enefunc_angl
  !> @brief        define ANGLE term for each cell in potential energy function
  !! @authors      YS, JJ, TM
  !! @param[in]    par      : CHARMM PAR information
  !! @param[in]    molecule : molecule information
  !! @param[in]    domain   : domain information
  !! @param[inout] enefunc  : potential energy functions information
  !
  !======1=========2=========3=========4=========5=========6=========7=========8

  subroutine setup_enefunc_angl(par, molecule, domain, enefunc)

    ! formal arguments
    type(s_par),     target, intent(in)    :: par
    type(s_molecule),target, intent(in)    :: molecule
    type(s_domain),  target, intent(in)    :: domain
    type(s_enefunc), target, intent(inout) :: enefunc

    ! local variables
    integer                  :: dupl, ioffset
    integer                  :: i, j, icel_local
    integer                  :: icel1, icel2
    integer                  :: nangl, nangl_p, found
    integer                  :: list(3)
    character(6)             :: ci1, ci2, ci3, ri1, ri2, ri3

    real(wp),        pointer :: force(:,:), theta(:,:)
    real(wp),        pointer :: ubforce(:,:), ubrmin(:,:)
    integer,         pointer :: angle(:), alist(:,:,:)
    integer,         pointer :: ncel
    integer(int2),   pointer :: cell_pair(:,:)
    integer(int2),   pointer :: id_g2l(:,:)
    integer,         pointer :: mol_angl_list(:,:)
    integer,         pointer :: sollist(:), nwater(:)
    character(6),    pointer :: mol_cls_name(:), mol_res_name(:)

    mol_angl_list => molecule%angl_list
    mol_cls_name  => molecule%atom_cls_name
    mol_res_name  => molecule%residue_name

    ncel      => domain%num_cell_local
    cell_pair => domain%cell_pair
    id_g2l    => domain%id_g2l
    nwater    => domain%num_water

    sollist   => enefunc%table%solute_list_inv
    angle     => enefunc%num_angle
    alist     => enefunc%angle_list
    force     => enefunc%angle_force_const
    theta     => enefunc%angle_theta_min
    ubforce   => enefunc%urey_force_const
    ubrmin    => enefunc%urey_rmin

    nangl     = molecule%num_angles
    nangl_p   = par%num_angles

    do dupl = 1, domain%num_duplicate

      ioffset = (dupl-1)*enefunc%table%num_solute

      do i = 1, nangl

        list(1:3) = mol_angl_list(1:3,i)
        ci1 = mol_cls_name(list(1))
        ci2 = mol_cls_name(list(2))
        ci3 = mol_cls_name(list(3))
        ri1 = mol_res_name(list(1))
        ri2 = mol_res_name(list(2))
        ri3 = mol_res_name(list(3))

        if (ri1(1:3) /= 'TIP' .and. ri1(1:3) /= 'WAT' .and. &
            ri1(1:3) /= 'SOL' .and. ri3(1:3) /= 'TIP' .and. &
            ri3(1:3) /= 'WAT' .and. ri3(1:3) /= 'SOL') then

          list(1:3) = sollist(list(1:3)) + ioffset

          icel1 = id_g2l(1,list(1))
          icel2 = id_g2l(1,list(3))

          if (icel1 /= 0 .and. icel2 /= 0) then

            icel_local = cell_pair(icel1,icel2)

            if (icel_local >= 1 .and. icel_local <= ncel) then

              do j = 1, nangl_p
                if ((ci1 == par%angl_atom_cls(1,j) .and. &
                     ci2 == par%angl_atom_cls(2,j) .and. &
                     ci3 == par%angl_atom_cls(3,j)) .or. &
                    (ci1 == par%angl_atom_cls(3,j) .and. &
                     ci2 == par%angl_atom_cls(2,j) .and. &
                     ci3 == par%angl_atom_cls(1,j))) then
  
                  angle(icel_local) = angle(icel_local) + 1
                  alist(1:3,angle(icel_local),icel_local) = list(1:3)
    
                  force(angle(icel_local),icel_local)   = &
                       par%angl_force_const(j)
                  theta(angle(icel_local),icel_local)   = &
                       par%angl_theta_min(j)*RAD
                  ubforce(angle(icel_local),icel_local) = &
                       par%angl_ub_force_const(j)
                  ubrmin(angle(icel_local),icel_local)  = &
                     par%angl_ub_rmin(j)
                  exit
  
                end if
              end do

              if (j == nangl_p + 1) &
                write(MsgOut,*) &
                  'Setup_Enefunc_Angl> not found ANGL: [',&
                  ci1, ']-[', ci2, ']-[', ci3, '] in parameter file. (ERROR)'
    
            end if
    
          end if

        end if

      end do

    end do

    ! angle from water
    !
    list(1:3) = enefunc%table%water_list(1:3,1)
    ci1 = molecule%atom_cls_name(list(2))
    ci2 = molecule%atom_cls_name(list(1))
    ci3 = molecule%atom_cls_name(list(3))
    do j = 1, nangl_p
      if ((ci1 .eq. par%angl_atom_cls(1, j) .and.  &
           ci2 .eq. par%angl_atom_cls(2, j) .and.  &
           ci3 .eq. par%angl_atom_cls(3, j)) .or.  &
          (ci1 .eq. par%angl_atom_cls(3, j) .and.  &
           ci2 .eq. par%angl_atom_cls(2, j) .and.  &
           ci1 .eq. par%angl_atom_cls(1, j))) then
        enefunc%table%HOH_angle = par%angl_theta_min(j)*RAD
        enefunc%table%HOH_force = par%angl_force_const(j)
        exit
      end if
    end do

    found = 0
    do i = 1, ncel
      found = found + angle(i)
      if (enefunc%table%water_bond_calc_OH) found = found + nwater(i)
      if (angle(i) > MaxAngle) &
        call error_msg('Setup_Enefunc_Angl> Too many angles.')
    end do

#ifdef MPI
    call mpi_allreduce(found, enefunc%num_angl_all, 1, mpi_integer, &
                       mpi_sum, mpi_comm_country, ierror)
#else
    enefunc%num_angl_all = found
#endif

    if (enefunc%num_angl_all /= nangl*domain%num_duplicate) &
      call error_msg('Setup_Enefunc_Angl> Some angle paremeters are missing.')

    return

  end subroutine setup_enefunc_angl

  !======1=========2=========3=========4=========5=========6=========7=========8
  !
  !  Subroutine    setup_enefunc_angl_constraint
  !> @brief        define ANGLE term for each cell in potential energy function
  !                with SETTLE constraint
  !! @authors      JJ
  !! @param[in]    par         : CHARMM PAR information
  !! @param[in]    molecule    : molecule information
  !! @param[in]    domain      : domain information
  !! @param[in]    constraints : constraints information
  !! @param[inout] enefunc     : potential energy functions information
  !
  !======1=========2=========3=========4=========5=========6=========7=========8

  subroutine setup_enefunc_angl_constraint(par, molecule, domain, &
                                           constraints, enefunc)

    ! formal arguments
    type(s_par),                 intent(in)    :: par
    type(s_molecule),    target, intent(in)    :: molecule
    type(s_domain),      target, intent(in)    :: domain
    type(s_constraints), target, intent(in)    :: constraints
    type(s_enefunc),     target, intent(inout) :: enefunc

    ! local variables
    integer                  :: dupl, ioffset
    integer                  :: i, j, icel_local
    integer                  :: icel1, icel2
    integer                  :: nangl, nangl_p, found
    integer                  :: list(3)
    character(6)             :: ci1, ci2, ci3
    character(6)             :: ri1, ri2, ri3
    integer                  :: nangl_per_water

    real(wp),        pointer :: force(:,:), theta(:,:)
    real(wp),        pointer :: ubforce(:,:), ubrmin(:,:)
    integer,         pointer :: angle(:), alist(:,:,:), num_water
    integer,         pointer :: ncel
    integer(int2),   pointer :: cell_pair(:,:)
    integer(int2),   pointer :: id_g2l(:,:)
    integer,         pointer :: mol_angl_list(:,:), mol_no(:)
    integer,         pointer :: nwater(:), sollist(:)
    character(6),    pointer :: mol_cls_name(:), mol_res_name(:)


    mol_angl_list  => molecule%angl_list
    mol_no         => molecule%molecule_no
    mol_cls_name   => molecule%atom_cls_name
    mol_res_name   => molecule%residue_name

    ncel      => domain%num_cell_local
    cell_pair => domain%cell_pair
    id_g2l    => domain%id_g2l
    nwater    => domain%num_water

    angle     => enefunc%num_angle
    alist     => enefunc%angle_list
    force     => enefunc%angle_force_const
    theta     => enefunc%angle_theta_min
    ubforce   => enefunc%urey_force_const
    ubrmin    => enefunc%urey_rmin
    num_water => enefunc%table%num_water
    sollist   => enefunc%table%solute_list_inv

    nangl     = molecule%num_angles
    nangl_p   = par%num_angles

    nangl_per_water = 0

    if (num_water > 0) then

      do i = 1, nangl
        list(1:3) = mol_angl_list(1:3,i)
        ri1 = mol_res_name(list(1))
        ri2 = mol_res_name(list(2))
        ri3 = mol_res_name(list(3))
        if (ri1(1:4) == constraints%water_model .and. &
            ri2(1:4) == constraints%water_model .and. &
            ri3(1:4) == constraints%water_model) then
          nangl_per_water = nangl_per_water + 1
        end if
      end do

      if (mod(nangl_per_water,num_water) /= 0) then
        write(MsgOut,*) &
             'Setup_Enefunc_Angl_Constraint> invalid ANGL count: ', &
             'number of angle terms in a water molecule is not integer.'
        call error_msg('Setup_Enefunc_Angl_Constraint> abort')
      end if
      nangl_per_water = nangl_per_water / num_water

    end if

    do dupl = 1, domain%num_duplicate

      ioffset = (dupl-1) * enefunc%table%num_solute

      do i = 1, nangl

        list(1:3) = mol_angl_list(1:3,i)
        ci1 = mol_cls_name(list(1))
        ci2 = mol_cls_name(list(2))
        ci3 = mol_cls_name(list(3))
        ri1 = mol_res_name(list(1))
        ri2 = mol_res_name(list(2))
        ri3 = mol_res_name(list(3))

        if (ri1(1:4) /= constraints%water_model .and. &
            ri2(1:4) /= constraints%water_model .and. &
            ri3(1:4) /= constraints%water_model) then

          list(1:3) = sollist(list(1:3)) + ioffset

          icel1 = id_g2l(1,list(1))
          icel2 = id_g2l(1,list(3))

          if (icel1 /= 0 .and. icel2 /= 0) then

            icel_local = cell_pair(icel1,icel2)

            if (icel_local >= 1 .and. icel_local <= ncel) then

              do j = 1, nangl_p
                if ((ci1 == par%angl_atom_cls(1,j) .and. &
                     ci2 == par%angl_atom_cls(2,j) .and. &
                     ci3 == par%angl_atom_cls(3,j)) .or. &
                    (ci1 == par%angl_atom_cls(3,j) .and. &
                     ci2 == par%angl_atom_cls(2,j) .and. &
                     ci3 == par%angl_atom_cls(1,j))) then
  
                  angle(icel_local) = angle(icel_local) + 1
                  alist(1:3,angle(icel_local),icel_local) = list(1:3)
  
                  force(angle(icel_local),icel_local)   = &
                       par%angl_force_const(j)
                  theta(angle(icel_local),icel_local)   = &
                       par%angl_theta_min(j)*RAD
                  ubforce(angle(icel_local),icel_local) = &
                       par%angl_ub_force_const(j)
                  ubrmin(angle(icel_local),icel_local)  = &
                       par%angl_ub_rmin(j)
                  exit
  
                end if
              end do
  
              if (j == nangl_p + 1) &
                write(MsgOut,*) &
                  'Setup_Enefunc_Angl_Constraint> not found ANGL: [', &
                  ci1, ']-[', ci2, ']-[', ci3, '] in parameter file. (ERROR)'
  
            end if
  
          end if
  
        end if

      end do
    end do

    found = 0
    do i = 1, ncel
      found = found + angle(i)
      if (angle(i) > MaxAngle) &
        call error_msg('Setup_Enefunc_Angl_Constraint> Too many angles.')
    end do

#ifdef MPI
    call mpi_allreduce(found, enefunc%num_angl_all, 1, mpi_integer, &
                       mpi_sum, mpi_comm_country, ierror)
#else
    enefunc%num_angl_all = found
#endif

    if (enefunc%num_angl_all /= &
        domain%num_duplicate*(nangl - nangl_per_water*num_water)) &
      call error_msg( &
        'Setup_Enefunc_Angl_Constraint> Some angle paremeters are missing.')

    return

  end subroutine setup_enefunc_angl_constraint

  !======1=========2=========3=========4=========5=========6=========7=========8
  !
  !  Subroutine    setup_enefunc_dihe
  !> @brief        define DIHEDRAL term in potential energy function
  !! @authors      YS, JJ, TM
  !! @param[in]    par      : CHARMM PAR information
  !! @param[in]    molecule : molecule information
  !! @param[in]    domain   : domain information
  !! @param[inout] enefunc  : potential energy functions information
  !
  !======1=========2=========3=========4=========5=========6=========7=========8

  subroutine setup_enefunc_dihe(par, molecule, domain, enefunc)

    ! formal arguments
    type(s_par),      target, intent(in)    :: par
    type(s_molecule), target, intent(in)    :: molecule
    type(s_domain),   target, intent(in)    :: domain
    type(s_enefunc),  target, intent(inout) :: enefunc

    ! local variables
    integer                   :: dupl, ioffset
    integer                   :: ndihe, ndihe_p
    integer                   :: i, j, icel_local
    integer                   :: icel1, icel2
    integer                   :: found, nw_found
    integer                   :: list(4)
    character(6)              :: ci1, ci2, ci3, ci4

    real(wp),         pointer :: force(:,:), phase(:,:)
    integer,          pointer :: dihedral(:), dlist(:,:,:), period(:,:)
    integer,          pointer :: ncel, sollist(:)
    integer(int2),    pointer :: cell_pair(:,:)
    integer(int2),    pointer :: id_g2l(:,:)
    logical,      allocatable :: no_wild(:)
    integer,          pointer :: notation
    integer,          pointer :: mol_dihe_list(:,:)
    character(6),     pointer :: mol_cls_name(:)


    mol_dihe_list  => molecule%dihe_list
    mol_cls_name   => molecule%atom_cls_name

    ncel      => domain%num_cell_local
    cell_pair => domain%cell_pair
    id_g2l    => domain%id_g2l

    dihedral  => enefunc%num_dihedral
    dlist     => enefunc%dihe_list
    force     => enefunc%dihe_force_const
    period    => enefunc%dihe_periodicity
    phase     => enefunc%dihe_phase
    notation  => enefunc%notation_14types
    sollist   => enefunc%table%solute_list_inv
    notation = 100

    ndihe     = molecule%num_dihedrals
    ndihe_p   = par%num_dihedrals

    ! check usage of wild card
    !
    allocate(no_wild(ndihe_p))

    do i = 1, ndihe_p

      if ((par%dihe_atom_cls(1,i) /= WildCard) .and. &
          (par%dihe_atom_cls(4,i) /= WildCard)) then
        ! A-B-C-D type
        no_wild(i) = .true.
      else
        ! X-B-C-D type
        no_wild(i) = .false.
      end if

    end do

    ! find number of interactions
    !
    do dupl = 1, domain%num_duplicate

      ioffset = (dupl-1) * enefunc%table%num_solute

      do i = 1, ndihe

        list(1:4) = mol_dihe_list(1:4,i)
        ci1 = mol_cls_name(list(1))
        ci2 = mol_cls_name(list(2))
        ci3 = mol_cls_name(list(3))
        ci4 = mol_cls_name(list(4))

        list(1:4) = sollist(list(1:4)) + ioffset

        icel1 = id_g2l(1,list(1))
        icel2 = id_g2l(1,list(4))

        if (icel1 /= 0 .and. icel2 /= 0) then

          icel_local = cell_pair(icel1,icel2)

          if (icel_local >= 1 .and. icel_local <= ncel) then

            nw_found = 0
            do j = 1, ndihe_p
              if (no_wild(j)) then
                if (((ci1 == par%dihe_atom_cls(1,j)) .and. &
                     (ci2 == par%dihe_atom_cls(2,j)) .and. &
                     (ci3 == par%dihe_atom_cls(3,j)) .and. &
                     (ci4 == par%dihe_atom_cls(4,j))) .or. &
                    ((ci1 == par%dihe_atom_cls(4,j)) .and. &
                     (ci2 == par%dihe_atom_cls(3,j)) .and. &
                     (ci3 == par%dihe_atom_cls(2,j)) .and. &
                     (ci4 == par%dihe_atom_cls(1,j)))) then
  
                  nw_found = nw_found + 1
                  dihedral(icel_local) = dihedral(icel_local) + 1
                  dlist(1:4,dihedral(icel_local),icel_local) = list(1:4)
  
                  force (dihedral(icel_local),icel_local) = &
                       par%dihe_force_const(j)
                  period(dihedral(icel_local),icel_local) = &
                       par%dihe_periodicity(j)
                  phase (dihedral(icel_local),icel_local) = &
                       par%dihe_phase(j) * RAD
  
                  if (period(dihedral(icel_local),icel_local) >  &
                  enefunc%notation_14types) &
                  call error_msg('Setup_Enefunc_Dihe> Too many periodicity.')
  
                end if
              end if
            end do
  
            if (nw_found == 0) then
              do j = 1, ndihe_p
                if (.not.no_wild(j)) then
                  if (((ci2 == par%dihe_atom_cls(2,j)) .and. &
                       (ci3 == par%dihe_atom_cls(3,j))) .or. &
                      ((ci2 == par%dihe_atom_cls(3,j)) .and. &
                       (ci3 == par%dihe_atom_cls(2,j)))) then
  
                    dihedral(icel_local) = dihedral(icel_local) + 1
                    dlist(1:4,dihedral(icel_local),icel_local) = list(1:4)
  
                    force (dihedral(icel_local),icel_local) = &
                         par%dihe_force_const(j)
                    period(dihedral(icel_local),icel_local) = &
                         par%dihe_periodicity(j)
                    phase (dihedral(icel_local),icel_local) = &
                         par%dihe_phase(j) * RAD
                    if (period(dihedral(icel_local),icel_local) >  &
                    enefunc%notation_14types) &
                    call error_msg('Setup_Enefunc_Dihe> Too many periodicity.')
  
                  end if
                end if
              end do
            end if
  
          end if

        end if

      end do

    end do

    deallocate(no_wild)

    found = 0
    do i = 1, ncel
      found = found + dihedral(i)
      if (dihedral(i) > MaxDihe) &
        call error_msg('Setup_Enefunc_Dihe> Too many dihedral angles.')
    end do

#ifdef MPI
    call mpi_allreduce(found, enefunc%num_dihe_all, 1, mpi_integer, &
                       mpi_sum, mpi_comm_country, ierror)
#else
    enefunc%num_dihe_all = found
#endif

    if (enefunc%num_dihe_all < ndihe*domain%num_duplicate) &
      call error_msg( &
         'Setup_Enefunc_Dihe> Some dihedral paremeters are missing.')

    return

  end subroutine setup_enefunc_dihe

  !======1=========2=========3=========4=========5=========6=========7=========8
  !
  !  Subroutine    setup_enefunc_impr
  !> @brief        define IMPROPER term in potential energy function
  !! @authors      YS,JJ
  !! @param[in]    par      : CHARMM PAR information
  !! @param[in]    molecule : molecule information
  !! @param[in]    domain   : domain information
  !! @param[inout] enefunc  : potential energy functions information
  !
  !======1=========2=========3=========4=========5=========6=========7=========8

  subroutine setup_enefunc_impr(par, molecule, domain, enefunc)

    ! formal variables
    type(s_par),      target, intent(in)    :: par
    type(s_molecule), target, intent(in)    :: molecule
    type(s_domain),   target, intent(in)    :: domain
    type(s_enefunc),  target, intent(inout) :: enefunc

    ! local variables
    integer                   :: dupl, ioffset
    integer                   :: nimpr, nimpr_p
    integer                   :: i, j, icel_local
    integer                   :: icel1, icel2
    integer                   :: found
    integer                   :: list(4)
    character(6)              :: ci1, ci2, ci3, ci4

    real(wp),         pointer :: force(:,:), phase(:,:)
    integer,          pointer :: improper(:), ilist(:,:,:)
    integer,          pointer :: ncel, sollist(:)
    integer(int2),    pointer :: cell_pair(:,:)
    integer(int2),    pointer :: id_g2l(:,:)
    integer,      allocatable :: wc_type(:)
    logical,      allocatable :: no_wild(:)
    integer,          pointer :: mol_impr_list(:,:)
    character(6),     pointer :: mol_cls_name(:)


    mol_impr_list  => molecule%impr_list
    mol_cls_name   => molecule%atom_cls_name

    ncel      => domain%num_cell_local
    cell_pair => domain%cell_pair
    id_g2l    => domain%id_g2l

    improper  => enefunc%num_improper
    ilist     => enefunc%impr_list
    force     => enefunc%impr_force_const
    phase     => enefunc%impr_phase
    sollist   => enefunc%table%solute_list_inv

    nimpr     = molecule%num_impropers
    nimpr_p   = par%num_impropers

    ! check usage of wild card
    !
    allocate(wc_type(nimpr_p), no_wild(nimpr))

    do i = 1, nimpr_p

      if ((par%impr_atom_cls(1,i) /= WildCard) .and. &
          (par%impr_atom_cls(2,i) /= WildCard) .and. &
          (par%impr_atom_cls(3,i) /= WildCard) .and. &
          (par%impr_atom_cls(4,i) /= WildCard)) then

        ! A-B-C-D type
        wc_type(i) = 0

      else if ((par%impr_atom_cls(1,i) == WildCard) .and. &
               (par%impr_atom_cls(2,i) /= WildCard) .and. &
               (par%impr_atom_cls(3,i) /= WildCard) .and. &
               (par%impr_atom_cls(4,i) /= WildCard)) then

        ! X-B-C-D type
        wc_type(i) = 1

      else if ((par%impr_atom_cls(1,i) == WildCard) .and. &
               (par%impr_atom_cls(2,i) == WildCard) .and. &
               (par%impr_atom_cls(3,i) /= WildCard) .and. &
               (par%impr_atom_cls(4,i) /= WildCard)) then

        ! X-X-C-D type
        wc_type(i) = 2

      else if ((par%impr_atom_cls(1,i) /= WildCard) .and. &
               (par%impr_atom_cls(2,i) == WildCard) .and. &
               (par%impr_atom_cls(3,i) == WildCard) .and. &
               (par%impr_atom_cls(4,i) /= WildCard)) then

        ! A-X-X-D type
        wc_type(i) = 3

      else
        call error_msg('Setup_Enefunc_Impr> Undefined Wild Card')

      end if

    end do

    ! setup parameters
    !
    do dupl = 1, domain%num_duplicate

      ioffset = (dupl-1) * enefunc%table%num_solute

      do i = 1, nimpr

        no_wild(i) = .false.
  
        list(1:4) = mol_impr_list(1:4,i)
        ci1 = mol_cls_name(list(1))
        ci2 = mol_cls_name(list(2))
        ci3 = mol_cls_name(list(3))
        ci4 = mol_cls_name(list(4))

        list(1:4) = sollist(list(1:4)) + ioffset

        icel1 = id_g2l(1,list(1))
        icel2 = id_g2l(1,list(4))

        if (icel1 /= 0 .and. icel2 /= 0) then

          icel_local = cell_pair(icel1,icel2)

          if (icel_local >= 1 .and. icel_local <= ncel) then

            ! A-B-C-D type
            !
            do j = 1, nimpr_p
              if (wc_type(j) == 0) then
                if (((ci1 == par%impr_atom_cls(1,j)) .and. &
                     (ci2 == par%impr_atom_cls(2,j)) .and. &
                     (ci3 == par%impr_atom_cls(3,j)) .and. &
                     (ci4 == par%impr_atom_cls(4,j))) .or. &
                    ((ci1 == par%impr_atom_cls(4,j)) .and. &
                     (ci2 == par%impr_atom_cls(3,j)) .and. &
                     (ci3 == par%impr_atom_cls(2,j)) .and. &
                     (ci4 == par%impr_atom_cls(1,j)))) then
  
                  improper(icel_local) = improper(icel_local) + 1
                  ilist(1:4,improper(icel_local),icel_local) = list(1:4)
  
                  force(improper(icel_local),icel_local) = &
                       par%impr_force_const(j)
                  phase(improper(icel_local),icel_local) = &
                       par%impr_phase(j) * RAD
                  no_wild(i) = .true.
                  exit
  
                end if
              end if
            end do
  
            ! X-B-C-D type
            !
              if (.not.no_wild(i)) then
              do j = 1, nimpr_p
                if (wc_type(j) == 1) then
                  if (((ci2 == par%impr_atom_cls(2,j)) .and. &
                       (ci3 == par%impr_atom_cls(3,j)) .and. &
                       (ci4 == par%impr_atom_cls(4,j))) .or. &
                      ((ci2 == par%impr_atom_cls(4,j)) .and. &
                       (ci3 == par%impr_atom_cls(3,j)) .and. &
                       (ci4 == par%impr_atom_cls(2,j)))) then
  
                    improper(icel_local) = improper(icel_local) + 1
                    ilist(1:4,improper(icel_local),icel_local) = list(1:4)
  
                    force(improper(icel_local),icel_local) = &
                         par%impr_force_const(j)
                    phase(improper(icel_local),icel_local) = &
                         par%impr_phase(j) * RAD
                    no_wild(i) = .true.
                    exit
  
                  end if
                end if
              end do
            end if
    
            ! X-X-C-D type
            !
            if (.not.no_wild(i)) then
              do j = 1, nimpr_p
                if (wc_type(j) == 2) then
                  if (((ci3 == par%impr_atom_cls(3,j)) .and. &
                       (ci4 == par%impr_atom_cls(4,j))) .or. &
                      ((ci3 == par%impr_atom_cls(4,j)) .and. &
                       (ci4 == par%impr_atom_cls(3,j)))) then
  
                    improper(icel_local) = improper(icel_local) + 1
                    ilist(1:4,improper(icel_local),icel_local) = list(1:4)
  
                    force(improper(icel_local),icel_local) = &
                           par%impr_force_const(j)
                    phase(improper(icel_local),icel_local) = &
                         par%impr_phase(j) * RAD
                    no_wild(i) = .true.
                    exit
  
                  end if
                end if
              end do
            end if
  
            ! A-X-X-D type
            !
            if (.not.no_wild(i)) then
              do j = 1, nimpr_p
                if (wc_type(j) == 3) then
                  if (((ci1 == par%impr_atom_cls(1,j)) .and. &
                       (ci4 == par%impr_atom_cls(4,j))) .or. &
                          ((ci1 == par%impr_atom_cls(4,j)) .and. &
                       (ci4 == par%impr_atom_cls(1,j)))) then
      
                    improper(icel_local) = improper(icel_local) + 1
                    ilist(1:4,improper(icel_local),icel_local) = list(1:4)
  
                    force(improper(icel_local),icel_local) = &
                         par%impr_force_const(j)
                    phase(improper(icel_local),icel_local) = &
                         par%impr_phase(j) * RAD
                    no_wild(i) = .true.
                    exit
  
                  end if
                end if
              end do
            end if

            if (.not.no_wild(i)) &
              write(MsgOut,*) &
                'Setup_Enefunc_Impr> Unknown IMPR type. [', &
                ci1, ']-[', ci2, ']-[', ci3, ']-[', ci4, '] (ERROR)'
  
          end if
        end if

      end do

    end do

    deallocate(wc_type, no_wild)

    found = 0
    do i = 1, ncel
      found = found + improper(i)
      if (improper(i) > MaxImpr) &
        call error_msg('Setup_Enefunc_Impr> Too many improper dihedral angles')
    end do

#ifdef MPI
    call mpi_allreduce(found, enefunc%num_impr_all, 1, mpi_integer, mpi_sum, &
                       mpi_comm_country, ierror)
#else
    enefunc%num_impr_all = found
#endif

    if (enefunc%num_impr_all < nimpr*domain%num_duplicate) &
      call error_msg( &
        'Setup_Enefunc_Impr> Some improper paremeters are missing.')

    return

  end subroutine setup_enefunc_impr

  !======1=========2=========3=========4=========5=========6=========7=========8
  !
  !  Subroutine    setup_enefunc_cmap
  !> @brief        define cmap term in potential energy function with DD
  !! @authors      TY, TM
  !! @param[in]    ene_info    : ENERGY section control parameters information
  !! @param[in]    par         : CHARMM PAR information
  !! @param[in]    molecule    : molecule information
  !! @param[in]    domain      : domain information
  !! @param[inout] enefunc     : energy potential functions informationn
  !!
  !! @note       In str "par", following variables have been defined:
  !!   cmap_atom_cls(8,imap) (char) : 8 atom classes (4 for phi and 4 for psi)
  !!   cmap_resolution(imap) (int ) : = 24 (for all imap) = 360degree/15degree
  !!   cmap_data(i,j,imap)   (real) : Ecmap for grid points. i and j are the
  !!                                  1st (psi?) and the 2nd (phi?) grid IDs.
  !!                                  1<=i,j<=24.
  !!   Where imap is ID of cmap type (1 <= imap <= 6).
  !!
  !! @note       TY determined to use natural spline (periodic = .false.)
  !!             because it is similar to the CHARMM way.
  !!             However, I notice that force will be more accurately continuous
  !!             at phi (or psi) = +-180 degree if periodic spline was used.
  !
  !======1=========2=========3=========4=========5=========6=========7=========8

  subroutine setup_enefunc_cmap(ene_info, par, molecule, domain, enefunc)

    ! formal variables
    type(s_ene_info),        intent(in)    :: ene_info
    type(s_par),             intent(in)    :: par
    type(s_molecule),target, intent(in)    :: molecule
    type(s_domain),  target, intent(in)    :: domain
    type(s_enefunc), target, intent(inout) :: enefunc

    ! local variables
    integer                  :: dupl, ioffset
    integer                  :: i, j, k, l, ityp
    integer                  :: ncmap_p, found, ngrid0
    integer                  :: list(8), icel1, icel2, icel_local
    integer                  :: flag_cmap_type, alloc_stat, dealloc_stat
    character(6)             :: ci1, ci2, ci3, ci4, ci5, ci6, ci7, ci8
    logical                  :: periodic

    integer,         pointer :: ncel, sollist(:)
    integer(int2),   pointer :: cell_pair(:,:)
    integer(int2),   pointer :: id_g2l(:,:)
    integer,         pointer :: mol_cmap_list(:,:)
    character(6),    pointer :: mol_cls_name(:)

    real(wp),    allocatable :: c_ij(:,:,:,:) ! cmap coeffs

    mol_cmap_list   => molecule%cmap_list
    mol_cls_name    => molecule%atom_cls_name

    ncel            => domain%num_cell_local
    cell_pair       => domain%cell_pair
    id_g2l          => domain%id_g2l

    sollist         => enefunc%table%solute_list_inv

    ! If 'periodic' is .true.,
    !   then cubic spline with periodic (in dihedral-angle space) boundary
    !   will be applied.
    ! If 'periodic' is .false.,
    !   then natural cubic spline without periodic boudnary
    !   will be applied to expanded cross-term maps.
    !   This is similar with CHARMM's source code.
    !
    periodic = ene_info%cmap_pspline
    ncmap_p  = par%num_cmaps

    ! begin
    !
    ngrid0 = 0
    do i = 1, ncmap_p
      ngrid0 = max(ngrid0, par%cmap_resolution(i))
    end do

    call alloc_enefunc(enefunc, EneFuncCmap, ncel, ngrid0, ncmap_p)

    alloc_stat = 0
    allocate(c_ij(4,4,ngrid0,ngrid0), stat = alloc_stat)
    if (alloc_stat /= 0) &
      call error_msg_alloc

    do i = 1, ncmap_p
      enefunc%cmap_resolution(i) = par%cmap_resolution(i)
    end do

    ! derive cmap coefficients by bicubic interpolation
    !
    do ityp = 1, ncmap_p

      if (periodic) then
        call derive_cmap_coefficients_p(ityp, par, c_ij)
      else
        call derive_cmap_coefficients_np(ityp, par, c_ij)
      end if

      do l = 1, ngrid0
        do k = 1, ngrid0
          do j = 1, 4
            do i = 1, 4
              enefunc%cmap_coef(i,j,k,l,ityp) = c_ij(i,j,k,l)
            end do
          end do
        end do
      end do
    end do

    enefunc%num_cmap(1:ncel) = 0

    do dupl = 1, domain%num_duplicate

      ioffset = (dupl-1) * enefunc%table%num_solute

      do i = 1, molecule%num_cmaps

        list(1:8) = mol_cmap_list(1:8,i) 

        icel1 = id_g2l(1,sollist(list(1))+ioffset)
        icel2 = id_g2l(1,sollist(list(8))+ioffset)

        if (icel1 /= 0 .and. icel2 /= 0) then

          icel_local = cell_pair(icel1,icel2)

          if (icel_local >= 1 .and. icel_local <= ncel) then

            ! ci* will be atom-type strings
            !
            ci1 = mol_cls_name(list(1))
            ci2 = mol_cls_name(list(2))
            ci3 = mol_cls_name(list(3))
            ci4 = mol_cls_name(list(4))
            ci5 = mol_cls_name(list(5))
            ci6 = mol_cls_name(list(6))
            ci7 = mol_cls_name(list(7))
            ci8 = mol_cls_name(list(8))
            flag_cmap_type = -1
  
            ! assign cmap type ID to each (psi,phi) pair
            !
            do j = 1, ncmap_p
              if (ci1 == par%cmap_atom_cls(1, j) .and. &
                  ci2 == par%cmap_atom_cls(2, j) .and.   &
                  ci3 == par%cmap_atom_cls(3, j) .and.   &
                  ci4 == par%cmap_atom_cls(4, j) .and.   &
                  ci5 == par%cmap_atom_cls(5, j) .and.   &
                  ci6 == par%cmap_atom_cls(6, j) .and.   &
                  ci7 == par%cmap_atom_cls(7, j) .and.   &
                  ci8 == par%cmap_atom_cls(8, j)   ) then
  
                enefunc%num_cmap(icel_local) = enefunc%num_cmap(icel_local) + 1
                enefunc%cmap_list(1:8,enefunc%num_cmap(icel_local),icel_local) &
                     = sollist(mol_cmap_list(1:8,i))+ioffset
                enefunc%cmap_type(enefunc%num_cmap(icel_local),icel_local) = j
                flag_cmap_type = j
                exit
  
              end if
            end do

            ! if not found, print detail about the error.
            !
  
            if (flag_cmap_type <= 0) then
              write(MsgOut,*) 'Setup_Enefunc_Cmap> not found CMAP: '
              write(MsgOut,*) ' [',ci1,']-[',ci2,']-[',ci3,']-[',ci4,']-'
              write(MsgOut,*) ' [',ci5,']-[',ci6,']-[',ci7,']-[',ci8,'] '
              write(MsgOut,*) '  in parameter file. (ERROR)'
            end if
  
          end if
        end if

      end do

    end do

    deallocate(c_ij, stat=dealloc_stat)
    if (dealloc_stat /= 0) &
      call error_msg_dealloc

    ! write summary
    !
    if (main_rank) then
      if (periodic) then
        write(MsgOut,'(A)') &
    'Setup_Enefunc_Cmap> Periodic-boundary spline is used to derive cmap coefs.'
        write(MsgOut,'(A)') ''
      else
        write(MsgOut,'(A)') &
            'Setup_Enefunc_Cmap> Natural spline is used to derive cmap coefs.'
        write(MsgOut,'(A)') ''
      end if
    end if

    ! stop if parameter is missing
    !
    found = 0
    do i = 1, ncel
      found = found + enefunc%num_cmap(i)
      if (enefunc%num_cmap(i) > MaxCmap) &
        call error_msg('Setup_Enefunc_Cmap> Too many cmaps.')
    end do

#ifdef MPI
    call mpi_allreduce(found, enefunc%num_cmap_all, 1, mpi_integer, mpi_sum, &
                       mpi_comm_country, ierror)
#else
    enefunc%num_cmap_all = found
#endif

    if (enefunc%num_cmap_all /=  molecule%num_cmaps*domain%num_duplicate) &
      call error_msg('Setup_Enefunc_Cmap> Some cmap parameters are missing.')

    return

  end subroutine setup_enefunc_cmap

  !======1=========2=========3=========4=========5=========6=========7=========8
  !
  !  Subroutine    setup_enefunc_nonb
  !> @brief        define NON-BOND term in potential energy function
  !! @authors      YS, JJ, TI
  !! @param[in]    par         : CHARMM PAR information
  !! @param[in]    molecule    : molecule information
  !! @param[in]    constraints : constraints information
  !! @param[inout] domain      : domain information
  !! @param[inout] enefunc     : energy potential functions information
  !
  !======1=========2=========3=========4=========5=========6=========7=========8

  subroutine setup_enefunc_nonb(par, molecule, constraints, domain, enefunc)

    ! formal arguments
    type(s_par),             intent(in)    :: par
    type(s_molecule),        intent(in)    :: molecule
    type(s_constraints),     intent(in)    :: constraints
    type(s_domain),          intent(inout) :: domain
    type(s_enefunc),         intent(inout) :: enefunc

    ! local variables
    real(wp)                 :: eps14, rmin14, eps, rmin, lamda_i, lamda_j
    real(dp)                 :: vdw_self1, vdw_self2
    integer                  :: i, j, k, ix, jx, kk
    integer                  :: nonb_p, nbfx_p, cls_local, ncel
    character(6)             :: ci1, ci2

    integer,  allocatable    :: nonb_atom_cls(:), check_cls(:)
    integer,  allocatable    :: atmcls_map_g2l(:), atmcls_map_l2g(:)
    real(wp), allocatable    :: nb14_lj6(:,:), nb14_lj12(:,:)
    real(wp), allocatable    :: nonb_lj6(:,:), nonb_lj12(:,:)
    real(wp), allocatable    :: lj_coef(:,:)

    enefunc%num_atom_cls = par%num_atom_cls

    ELECOEF          = ELECOEF_CHARMM

    ! set lennard-jones parameters
    !
    nonb_p = enefunc%num_atom_cls

    allocate(nonb_atom_cls(nonb_p),     &
             check_cls(nonb_p),         &
             atmcls_map_g2l(nonb_p),    &
             atmcls_map_l2g(nonb_p),    &
             nb14_lj6 (nonb_p, nonb_p), &
             nb14_lj12(nonb_p, nonb_p), &
             nonb_lj6 (nonb_p, nonb_p), &
             nonb_lj12(nonb_p, nonb_p), &
             lj_coef(2,nonb_p))

    nonb_atom_cls(1:nonb_p)           = 0
    check_cls(1:nonb_p)               = 0
    nb14_lj6 (1:nonb_p, 1:nonb_p) = 0.0_wp
    nb14_lj12(1:nonb_p, 1:nonb_p) = 0.0_wp
    nonb_lj6 (1:nonb_p, 1:nonb_p) = 0.0_wp
    nonb_lj12(1:nonb_p, 1:nonb_p) = 0.0_wp
    lj_coef  (1:2,1:nonb_p)       = 0.0_wp 

    do i = 1, nonb_p

      lj_coef(1,i) = abs(par%nonb_eps(i))
      lj_coef(2,i) = par%nonb_rmin(i)

      do j = 1, nonb_p

        ! combination rule
        eps14  = sqrt(par%nonb_eps_14(i) * par%nonb_eps_14(j))
        rmin14 = par%nonb_rmin_14(i) + par%nonb_rmin_14(j)
        eps    = sqrt(par%nonb_eps(i) * par%nonb_eps(j))
        rmin   = par%nonb_rmin(i) + par%nonb_rmin(j)

        ! set parameters
        nb14_lj12(i,j) = eps14 * (rmin14 ** 12)
        nb14_lj6(i,j)  = 2.0_wp * eps14 * (rmin14 ** 6)
        nonb_lj12(i,j) = eps * (rmin ** 12)
        nonb_lj6(i,j)  = 2.0_wp * eps * (rmin ** 6)

      end do
    end do

    ! overwrite lennard-jones parameters by NBFIX parameters
    !
    nbfx_p = par%num_nbfix

    do k = 1, nbfx_p
      ci1 = par%nbfi_atom_cls(1,k)
      ci2 = par%nbfi_atom_cls(2,k)
      do i = 1, nonb_p
        do j = 1, nonb_p
          if ((ci1 == par%nonb_atom_cls(i)  .and. &
               ci2 == par%nonb_atom_cls(j)) .or.  &
              (ci2 == par%nonb_atom_cls(i) .and. &
               ci1 == par%nonb_atom_cls(j))) then

            ! combination rule
            !
            eps14  = abs(par%nbfi_eps_14 (k)) !TODO CHECK
            rmin14 = par%nbfi_rmin_14(k)
            eps    = abs(par%nbfi_eps    (k))
            rmin   = par%nbfi_rmin   (k)

            ! set parameters
            !
            nb14_lj12(i,j) = eps14 * (rmin14 ** 12)
            nb14_lj6 (i,j) = 2.0_wp * eps14 * (rmin14 ** 6)
            nonb_lj12(i,j) = eps * (rmin ** 12)
            nonb_lj6 (i,j) = 2.0_wp * eps * (rmin ** 6)
          end if
        end do
      end do
    end do

    ! check the usage of atom class
    !
    do i = 1, molecule%num_atoms
      k = molecule%atom_cls_no(i)
      if (k < 1) then
        call error_msg( &
        'Setup_Enefunc_Nonb> atom class is not defined: "'&
        //trim(molecule%atom_cls_name(i))//'"')
      endif
      check_cls(k) = check_cls(k) + 1
    end do

    k = 0
    do i = 1, nonb_p
      if (check_cls(i) > 0) then
        k = k + 1
        atmcls_map_g2l(i) = k
        atmcls_map_l2g(k) = i
      end if
    end do
    cls_local = k
    max_class = cls_local

    call alloc_enefunc(enefunc, EneFuncNbon, cls_local)

    do i = 1, cls_local
      ix = atmcls_map_l2g(i)
      enefunc%nonb_lj6_factor(i)  = sqrt(2.0_wp)*8.0_wp*sqrt(lj_coef(1,ix))  &
                                   *lj_coef(2,ix)**3
      enefunc%nonb_atom_cls_no(i) = check_cls(ix)
    end do

    do i = 1, cls_local
      ix = atmcls_map_l2g(i)
      do j = 1, cls_local
        jx = atmcls_map_l2g(j)
        enefunc%nb14_lj12(i,j) = nb14_lj12(ix,jx)
        enefunc%nb14_lj6 (i,j) = nb14_lj6 (ix,jx)
        enefunc%nonb_lj12(i,j) = nonb_lj12(ix,jx)
        enefunc%nonb_lj6 (i,j) = nonb_lj6 (ix,jx)
      end do
    end do

    ! Sum of lamda_i*lamda_j and lamda_i*lamda_i
    !
    vdw_self1 = 0.0_dp
    vdw_self2 = 0.0_dp
    k = 0
    do i = 1, cls_local
      ix = enefunc%nonb_atom_cls_no(i)
      lamda_i = enefunc%nonb_lj6_factor(i)
      vdw_self2 = vdw_self2 + ix*lamda_i*lamda_i
      do j = 1, cls_local 
        jx = enefunc%nonb_atom_cls_no(j)
        lamda_j = enefunc%nonb_lj6_factor(j)
        vdw_self1 = vdw_self1 + ix*jx*lamda_i*lamda_j
      end do
    end do
    enefunc%pme_dispersion_self1 = real(vdw_self1,wp)
    enefunc%pme_dispersion_self2 = real(vdw_self2,wp)

    ! update domain information
    !
    do i = 1, domain%num_cell_local+domain%num_cell_boundary
      do ix = 1, domain%num_atom(i)
        domain%atom_cls_no(ix,i) = atmcls_map_g2l(domain%atom_cls_no(ix,i))
      end do
    end do
    domain%water%atom_cls_no(1:3)  &
      = atmcls_map_g2l(domain%water%atom_cls_no(1:3))
    enefunc%table%atom_cls_no_O = atmcls_map_g2l(enefunc%table%atom_cls_no_O)
    enefunc%table%atom_cls_no_H = atmcls_map_g2l(enefunc%table%atom_cls_no_H)
    if (constraints%tip4) then
      domain%water%atom_cls_no(4) = atmcls_map_g2l(domain%water%atom_cls_no(4))
      enefunc%table%atom_cls_no_D = atmcls_map_g2l(enefunc%table%atom_cls_no_D)
    end if

    deallocate(nonb_atom_cls,  &
               check_cls,      &
               atmcls_map_g2l, &
               atmcls_map_l2g, &
               nb14_lj6,       &
               nb14_lj12,      &
               nonb_lj6,       &
               nonb_lj12,      & 
               lj_coef)

    enefunc%num_atom_cls = cls_local

    ! treatment for 1-2, 1-3, 1-4 interactions
    !
    ncel   = domain%num_cell_local

    call alloc_enefunc(enefunc, EneFuncNonb,     ncel, maxcell_near)
    call alloc_enefunc(enefunc, EneFuncNonbList, ncel, maxcell_near)

    if (constraints%rigid_bond) then

      call count_nonb_excl(.true., .true., constraints, domain, enefunc)

    else

      call count_nonb_excl(.true., .false., constraints, domain, enefunc)

    end if

    return

  end subroutine setup_enefunc_nonb

  !======1=========2=========3=========4=========5=========6=========7=========8
  !
  !  Subroutine    count_nonb_excl
  !> @brief        exclude 1-2, 1-3 interactions and constraints
  !! @authors      JJ
  !! @param[in]    first       : flag for first call or not
  !! @param[in]    constraint  : flag for constraint usage
  !! @param[in]    constraints : constraints information   
  !! @param[inout] domain      : structure of domain
  !! @param[inout] enefunc     : structure of enefunc
  !
  !======1=========2=========3=========4=========5=========6=========7=========8

  subroutine count_nonb_excl(first, constraint, constraints, domain, enefunc)

    ! formal arguments
    logical,                     intent(in)    :: first
    logical,                     intent(in)    :: constraint
    type(s_constraints), target, intent(in)    :: constraints
    type(s_domain),      target, intent(inout) :: domain
    type(s_enefunc),     target, intent(inout) :: enefunc

    ! local variables
    integer                  :: ncell, ncell_local, i, ii, ix, k, i1, i2, i3
    integer                  :: icel, icel1, icel2
    integer                  :: ic, j, ih, ij, index(4)
    integer                  :: num_excl, num_nb14, id, omp_get_thread_num
    integer                  :: found1, found2
    integer                  :: fkind
    integer                  :: list1, list2

    integer,         pointer :: natom(:), nwater(:)
    integer(int2),   pointer :: id_g2l(:,:)
    integer,         pointer :: water_list(:,:,:)
    integer,         pointer :: nbond(:), bond_list(:,:,:)
    integer,         pointer :: nangle(:), angl_list(:,:,:)
    integer(1),      pointer :: bond_kind(:,:), angl_kind(:,:), dihe_kind(:,:)
    integer,         pointer :: ndihedral(:), dihe_list(:,:,:)
    integer,         pointer :: cell_pairlist2(:,:)
    integer(int2),   pointer :: cell_pair(:,:)
    integer,         pointer :: nonb_excl_list(:,:,:)
    integer,         pointer :: nb14_calc_list(:,:,:)
    integer(1),      pointer :: exclusion_mask(:,:,:), exclusion_mask1(:,:,:)
    integer,         pointer :: sc_calc_list(:,:)
    integer,         pointer :: num_nonb_excl(:), num_nb14_calc(:)
    integer,         pointer :: HGr_local(:,:), HGr_bond_list(:,:,:,:)
    real(wp),        pointer :: nb14_qq_scale(:,:), nb14_lj_scale(:,:)
    real(wp),        pointer :: dihe_scnb(:), dihe_scee(:)
    real(wp),        pointer :: charge(:,:)

    natom           => domain%num_atom
    nwater          => domain%num_water
    water_list      => domain%water_list
    id_g2l          => domain%id_g2l
    cell_pair       => domain%cell_pairlist1
    cell_pairlist2  => domain%cell_pairlist2
    charge          => domain%charge

    nbond           => enefunc%num_bond
    nangle          => enefunc%num_angle
    ndihedral       => enefunc%num_dihedral
    bond_list       => enefunc%bond_list
    bond_kind       => enefunc%bond_kind
    angl_list       => enefunc%angle_list
    angl_kind       => enefunc%angle_kind
    dihe_list       => enefunc%dihe_list
    dihe_kind       => enefunc%dihe_kind
    nonb_excl_list  => enefunc%nonb_excl_list
    nb14_calc_list  => enefunc%nb14_calc_list
    sc_calc_list    => enefunc%sc_calc_list
    num_nonb_excl   => enefunc%num_nonb_excl
    num_nb14_calc   => enefunc%num_nb14_calc
    exclusion_mask  => enefunc%exclusion_mask
    exclusion_mask1 => enefunc%exclusion_mask1
    nb14_qq_scale   => enefunc%nb14_qq_scale
    nb14_lj_scale   => enefunc%nb14_lj_scale
    dihe_scnb       => enefunc%dihe_scnb
    dihe_scee       => enefunc%dihe_scee

    ncell_local = domain%num_cell_local
    ncell       = domain%num_cell_local + domain%num_cell_boundary

    domain%max_num_atom = 0
    do i = 1, ncell
      domain%max_num_atom = max(domain%max_num_atom,domain%num_atom(i))
    end do

    ! initialization
    !
    num_nonb_excl(1:ncell_local)  = 0
    num_nb14_calc(1:ncell_local)  = 0

#ifdef PKTIMER
    call timer_sta(214)
#ifdef FJ_PROF_FAPP
    call fapp_start("count_nonb_excl_omp_loop1",214,0)
#endif
#endif

    ! exclude 1-2 interaction
    !
    !$omp parallel default(shared)                                     &
    !$omp private(id, i, ix, icel1, icel2, icel, i1, i2, i3, num_excl, &
    !$omp         k, num_nb14, ic, j, ih, list1, list2, ii, ij, fkind, &
    !$omp         index)
    !
#ifdef OMP
    id = omp_get_thread_num()
#else
    id = 0
#endif

    do i = id+1, ncell_local, nthread
      k = natom(i)
      exclusion_mask1(1:k,1:k,i) = 1
      do i1 = 1, k
        exclusion_mask1(i1,i1,i) = 0
      end do
    end do
    do ij = id+1, maxcell_near, nthread
      i = cell_pair(1,ij)
      j = cell_pair(2,ij)
      i1 = max(natom(i),natom(j))
      exclusion_mask(1:i1,1:i1,ij) = 1
    end do
    !$omp barrier

    if (enefunc%excl_level > 0) then

      do i = id+1, ncell_local, nthread
        do ix = 1, nbond(i)

          fkind = bond_kind(ix,i)

          if (fkind == 0) then

            list1 = bond_list(1,ix,i)
            list2 = bond_list(2,ix,i)
            icel1 = id_g2l(1,list1)
            icel2 = id_g2l(1,list2)
            i1    = id_g2l(2,list1)
            i2    = id_g2l(2,list2)
            num_excl = num_nonb_excl(i) + 1
            num_nonb_excl(i) = num_excl
            nonb_excl_list(1,num_excl,i) = icel1
            nonb_excl_list(2,num_excl,i) = icel2
            nonb_excl_list(3,num_excl,i) = i1
            nonb_excl_list(4,num_excl,i) = i2

            if (icel1 /= icel2) then

              icel  = cell_pairlist2(icel1,icel2)
              if (icel1 < icel2) then
                exclusion_mask(i2,i1,icel) = 0
              else if (icel1 > icel2) then
                exclusion_mask(i1,i2,icel) = 0
              end if
  
            else

              if (i1 < i2) then
                exclusion_mask1(i2,i1,i) = 0
              else if (i1 > i2) then
                exclusion_mask1(i1,i2,i) = 0
              end if

            end if

          end if

        end do
      end do
   
      ! exclude constraint
      !
      if (constraint) then

        HGr_local       => constraints%HGr_local
        HGr_bond_list   => constraints%HGr_bond_list
        do icel = id+1, ncell_local, nthread
          do ic = 1, constraints%connect
            do j = 1, HGr_local(ic,icel)

              i1 = HGr_bond_list(1,j,ic,icel)
!ocl nosimd
              do ih = 1, ic
                i2 = HGr_bond_list(ih+1,j,ic,icel)
                num_excl = num_nonb_excl(icel) + 1
                num_nonb_excl(icel) = num_excl
                nonb_excl_list(1,num_excl,icel) = icel
                nonb_excl_list(2,num_excl,icel) = icel
                nonb_excl_list(3,num_excl,icel) = i1
                nonb_excl_list(4,num_excl,icel) = i2
                exclusion_mask1(i2,i1,icel) = 0
              end do

            end do
          end do
        end do

      end if

    end if

    !$omp barrier

    ! exclude water
    !
    if (enefunc%excl_level > 1) then

      if (constraints%tip4) then

        do icel = id+1, ncell_local, nthread
          do ic = 1, nwater(icel)

            index(1) = water_list(1,ic,icel)
            index(2) = water_list(2,ic,icel)
            index(3) = water_list(3,ic,icel)
            index(4) = water_list(4,ic,icel)

!ocl nosimd
            do i1 = 2, 3
              do i2 = i1+1, 4
                num_excl = num_nonb_excl(icel) + 1
                num_nonb_excl(icel) = num_excl
                nonb_excl_list(1,num_excl,icel) = icel
                nonb_excl_list(2,num_excl,icel) = icel
                nonb_excl_list(3,num_excl,icel) = index(i1)
                nonb_excl_list(4,num_excl,icel) = index(i2)
                exclusion_mask1(index(i2),index(i1),icel) = 0
              end do
            end do
            i1 = 1
            do i2 = 2, 4
              exclusion_mask1(index(i2),index(i1),icel) = 0
            end do

          end do
        end do

      else

        do icel = id+1, ncell_local, nthread
          do ic = 1, nwater(icel)

            index(1) = water_list(1,ic,icel)
            index(2) = water_list(2,ic,icel)
            index(3) = water_list(3,ic,icel)
          
            num_excl = num_nonb_excl(icel) + 1
            num_nonb_excl(icel) = num_excl
            nonb_excl_list(1,num_excl,icel) = icel
            nonb_excl_list(2,num_excl,icel) = icel
            nonb_excl_list(3,num_excl,icel) = index(1)
            nonb_excl_list(4,num_excl,icel) = index(2)
            num_excl = num_nonb_excl(icel) + 1
            num_nonb_excl(icel) = num_excl
            nonb_excl_list(1,num_excl,icel) = icel
            nonb_excl_list(2,num_excl,icel) = icel
            nonb_excl_list(3,num_excl,icel) = index(1)
            nonb_excl_list(4,num_excl,icel) = index(3)
            num_excl = num_nonb_excl(icel) + 1
            num_nonb_excl(icel) = num_excl
            nonb_excl_list(1,num_excl,icel) = icel
            nonb_excl_list(2,num_excl,icel) = icel
            nonb_excl_list(3,num_excl,icel) = index(2)
            nonb_excl_list(4,num_excl,icel) = index(3)

            exclusion_mask1(index(2),index(1),icel) = 0
            exclusion_mask1(index(3),index(1),icel) = 0
            exclusion_mask1(index(3),index(2),icel) = 0

          end do
        end do

      end if

      ! exclude 1-3 interaction
      !
      do i = id+1, ncell_local, nthread
        do ix = 1, nangle(i)

          fkind = angl_kind(ix,i)

          if (fkind == 0) then

            list1 = angl_list(1,ix,i)
            list2 = angl_list(3,ix,i)
            icel1 = id_g2l(1,list1)
            icel2 = id_g2l(1,list2)
            i1    = id_g2l(2,list1)
            i2    = id_g2l(2,list2)

            if (icel1 /= icel2) then

              icel  = cell_pairlist2(icel1,icel2)

              if (icel1 < icel2) then

                if (exclusion_mask(i2,i1,icel)==1) then
                  if (abs(charge(i1,icel1)) > EPS .and. &
                      abs(charge(i2,icel2)) > EPS) then
                    num_excl = num_nonb_excl(i) + 1
                    num_nonb_excl(i) = num_excl
                    nonb_excl_list(1,num_excl,i) = icel1
                    nonb_excl_list(2,num_excl,i) = icel2
                    nonb_excl_list(3,num_excl,i) = i1
                    nonb_excl_list(4,num_excl,i) = i2
                  end if
                  exclusion_mask(i2,i1,icel) = 0
                end if

              else if (icel1 > icel2) then

                if (exclusion_mask(i1,i2,icel)==1) then
                  if (abs(charge(i1,icel1)) > EPS .and. &
                      abs(charge(i2,icel2)) > EPS) then
                    num_excl = num_nonb_excl(i) + 1
                    num_nonb_excl(i) = num_excl
                    nonb_excl_list(1,num_excl,i) = icel1
                    nonb_excl_list(2,num_excl,i) = icel2
                    nonb_excl_list(3,num_excl,i) = i1
                    nonb_excl_list(4,num_excl,i) = i2
                  end if
                  exclusion_mask(i1,i2,icel) = 0
                end if

              end if

            else

              if (i1 < i2) then

                if (exclusion_mask1(i2,i1,i)==1) then
                  if (abs(charge(i1,icel1)) > EPS .and. &
                      abs(charge(i2,icel2)) > EPS) then
                    num_excl = num_nonb_excl(i) + 1
                    num_nonb_excl(i) = num_excl
                    nonb_excl_list(1,num_excl,i) = icel1
                    nonb_excl_list(2,num_excl,i) = icel2
                    nonb_excl_list(3,num_excl,i) = i1
                    nonb_excl_list(4,num_excl,i) = i2
                  end if
                  exclusion_mask1(i2,i1,i) = 0
                end if

              else if (i1 > i2) then

                if (exclusion_mask1(i1,i2,i)==1) then
                  if (abs(charge(i1,icel1)) > EPS .and. &
                      abs(charge(i2,icel2)) > EPS) then
                    num_excl = num_nonb_excl(i) + 1
                    num_nonb_excl(i) = num_excl
                    nonb_excl_list(1,num_excl,i) = icel1
                    nonb_excl_list(2,num_excl,i) = icel2
                    nonb_excl_list(3,num_excl,i) = i1
                    nonb_excl_list(4,num_excl,i) = i2
                  end if
                  exclusion_mask1(i1,i2,i) = 0
                end if

              end if

            end if

          end if
        end do
      end do

    end if

    !$omp end parallel

#ifdef PKTIMER
    call timer_end(214)
#ifdef FJ_PROF_FAPP
    call fapp_stop("count_nonb_excl_omp_loop1",214,0)
#endif
#endif

    ! count 1-4 interaction
    !
    if (enefunc%excl_level > 2) then

      do ii = 1, 2

        if (ii == 2) then
          ndihedral => enefunc%num_rb_dihedral
          dihe_list => enefunc%rb_dihe_list
        end if

        !$omp parallel default(shared)                                     &
        !$omp private(id, i, ix, icel1, icel2, icel, i1, i2, list1, list2, &
        !$omp         num_nb14, fkind)
        !
#ifdef OMP
        id = omp_get_thread_num()
#else
        id = 0
#endif
        do i = id+1, ncell_local, nthread

          do ix = 1, ndihedral(i)

            fkind = dihe_kind(ix,i)

            if (fkind == 0) then

              list1 = dihe_list(1,ix,i)
              list2 = dihe_list(4,ix,i)
              icel1 = id_g2l(1,list1)
              icel2 = id_g2l(1,list2)
              i1    = id_g2l(2,list1)
              i2    = id_g2l(2,list2)

              if (icel1 /= icel2) then

                icel  = cell_pairlist2(icel1,icel2)

                if (icel1 < icel2) then

                  if (exclusion_mask(i2,i1,icel)==1) then
                    num_nb14 = num_nb14_calc(i) + 1
                    num_nb14_calc(i) = num_nb14
                    nb14_calc_list(1,num_nb14,i) = icel1
                    nb14_calc_list(2,num_nb14,i) = icel2
                    nb14_calc_list(3,num_nb14,i) = i1
                    nb14_calc_list(4,num_nb14,i) = i2
                    sc_calc_list(num_nb14,i)     = &
                      int(enefunc%dihe_periodicity(ix,i)/enefunc%notation_14types)
                    exclusion_mask(i2,i1,icel) = 0
                  end if

                else if (icel1 > icel2) then

                  if (exclusion_mask(i1,i2,icel)==1) then
                    num_nb14 = num_nb14_calc(i) + 1
                    num_nb14_calc(i) = num_nb14
                    nb14_calc_list(1,num_nb14,i) = icel1
                    nb14_calc_list(2,num_nb14,i) = icel2
                    nb14_calc_list(3,num_nb14,i) = i1
                    nb14_calc_list(4,num_nb14,i) = i2
                    sc_calc_list(num_nb14,i)     = &
                      int(enefunc%dihe_periodicity(ix,i)/enefunc%notation_14types)
                    exclusion_mask(i1,i2,icel) = 0
                  end if

                end if

              else

                if (i1 < i2) then

                  if (exclusion_mask1(i2,i1,i)==1) then
                    num_nb14 = num_nb14_calc(i) + 1
                    num_nb14_calc(i) = num_nb14
                    nb14_calc_list(1,num_nb14,i) = icel1
                    nb14_calc_list(2,num_nb14,i) = icel2
                    nb14_calc_list(3,num_nb14,i) = i1
                    nb14_calc_list(4,num_nb14,i) = i2
                    sc_calc_list(num_nb14,i)     = &
                      int(enefunc%dihe_periodicity(ix,i)/enefunc%notation_14types)
                    exclusion_mask1(i2,i1,i) = 0
                  end if

                else if (i1 > i2) then

                  if (exclusion_mask1(i1,i2,i)==1) then
                    num_nb14 = num_nb14_calc(i) + 1
                    num_nb14_calc(i) = num_nb14
                    nb14_calc_list(1,num_nb14,i) = icel1
                    nb14_calc_list(2,num_nb14,i) = icel2
                    nb14_calc_list(3,num_nb14,i) = i1
                    nb14_calc_list(4,num_nb14,i) = i2
                    sc_calc_list(num_nb14,i)     = &
                      int(enefunc%dihe_periodicity(ix,i)/enefunc%notation_14types)
                    exclusion_mask1(i1,i2,i) = 0
                  end if

                end if

              end if

            end if
          end do
        end do
        !$omp end parallel

      end do

    end if

    ! scnb/fudge_lj & scee/fudge_qq
    !
    !$omp parallel default(shared)            &
    !$omp private(id, i, ix, list1, list2)
    !
#ifdef OMP
    id = omp_get_thread_num()
#else
    id = 0
#endif
    if (enefunc%forcefield == ForcefieldAMBER) then
      do i = id+1, ncell_local, nthread
        do ix = 1, num_nb14_calc(i)
          list1 = sc_calc_list(ix,i)
          nb14_lj_scale(ix,i) = dihe_scnb(list1)
          nb14_qq_scale(ix,i) = dihe_scee(list1)
        end do
      end do
    end if
    if (enefunc%forcefield == ForcefieldGROAMBER .or. &
        enefunc%forcefield == ForcefieldGROMARTINI) then
      do i = id+1, ncell_local, nthread
        do ix = 1, num_nb14_calc(i)
          list1 = sc_calc_list(ix,i)
          nb14_lj_scale(ix,i) = enefunc%fudge_lj
          nb14_qq_scale(ix,i) = enefunc%fudge_qq
        end do
      end do
    end if
    !$omp end parallel

    ! Check the total number of exclusion list
    !
    if (first) then

      found1 = 0
      found2 = 0

      do icel = 1, ncell_local
        found1 = found1 + num_nonb_excl(icel)
        found2 = found2 + num_nb14_calc(icel)
      end do

#ifdef MPI
      call mpi_reduce(found1, enefunc%num_excl_all, 1, mpi_integer, mpi_sum, &
                      0, mpi_comm_country, ierror)
      call mpi_reduce(found2, enefunc%num_nb14_all, 1, mpi_integer, mpi_sum, &
                      0, mpi_comm_country, ierror)
#else
    enefunc%num_excl_all = found1
    enefunc%num_nb14_all = found2
#endif
    end if

    return

  end subroutine count_nonb_excl

end module sp_enefunc_charmm_mod
