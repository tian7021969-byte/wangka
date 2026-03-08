@echo off
set LOGFILE=C:\Users\dukehhu\Desktop\amd\sim_full_output.log
set SIM_DIR=C:\Users\dukehhu\Desktop\amd\Audio_Controller_Logic\Audio_Controller_Logic.sim\sim_1\behav\xsim
set SRC_DIR=C:\Users\dukehhu\Desktop\amd

echo ===== AE-9 PCIe Simulation ===== > "%LOGFILE%"
echo Started: %date% %time% >> "%LOGFILE%"
echo. >> "%LOGFILE%"

cd /d "%SIM_DIR%"
call C:\Xilinx\Vivado\2022.2\settings64.bat

echo ===== Step 1: Compile ===== >> "%LOGFILE%" 2>&1
call xvlog -d SIMULATION ^
  "%SRC_DIR%\sim_stubs.v" ^
  "%SRC_DIR%\hda_pcie_top.v" ^
  "%SRC_DIR%\pcileech_pcie_cfg_a7.v" ^
  "%SRC_DIR%\bar0_hda_sim.v" ^
  "%SRC_DIR%\hda_codec_engine.v" ^
  "%SRC_DIR%\hda_dma_engine.v" ^
  "%SRC_DIR%\tlp_tag_randomizer.v" ^
  "%SRC_DIR%\tx_arbiter.v" ^
  "%SRC_DIR%\tb_hda_pcie_top.v" ^
  --work xil_defaultlib ^
  -log xvlog.log >> "%LOGFILE%" 2>&1
echo Compile exit code: %errorlevel% >> "%LOGFILE%"
if errorlevel 1 (
    echo [ERROR] Compile failed! See %LOGFILE% >> "%LOGFILE%"
    type xvlog.log >> "%LOGFILE%" 2>nul
    echo.
    echo [ERROR] Compile failed! Check sim_full_output.log
    pause
    exit /b 1
)
echo. >> "%LOGFILE%"

echo ===== Step 2: Elaborate ===== >> "%LOGFILE%" 2>&1
call xelab --debug typical --relax --mt 2 -d "SIMULATION=" -L xil_defaultlib -L unisims_ver -L unimacro_ver -L secureip -L xpm --snapshot tb_hda_pcie_top_behav xil_defaultlib.tb_hda_pcie_top xil_defaultlib.glbl -log elaborate.log >> "%LOGFILE%" 2>&1
echo Elaborate exit code: %errorlevel% >> "%LOGFILE%"
if errorlevel 1 (
    echo [ERROR] Elaborate failed! See %LOGFILE% >> "%LOGFILE%"
    type elaborate.log >> "%LOGFILE%" 2>nul
    echo.
    echo [ERROR] Elaborate failed! Check sim_full_output.log
    pause
    exit /b 1
)
echo. >> "%LOGFILE%"

echo ===== Step 3: Simulate ===== >> "%LOGFILE%" 2>&1
call xsim tb_hda_pcie_top_behav --runall --log simulate.log >> "%LOGFILE%" 2>&1
echo Simulate exit code: %errorlevel% >> "%LOGFILE%"

echo. >> "%LOGFILE%"
echo ===== Done: %date% %time% ===== >> "%LOGFILE%"

echo.
echo ========================================
echo  Simulation complete!
echo  Output: %LOGFILE%
echo ========================================
echo.
pause
