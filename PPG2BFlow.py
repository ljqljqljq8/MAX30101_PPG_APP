import numpy as np
import pandas as pd
import matplotlib.pyplot as plt
from scipy.signal import butter, filtfilt, find_peaks

def butter_bandpass_filter(data, lowcut, highcut, fs, order=2):
    """带通滤波器，去除基线漂移和高频噪声"""
    nyq = 0.5 * fs
    low = lowcut / nyq
    high = highcut / nyq
    b, a = butter(order, [low, high], btype='bandpass')
    y = filtfilt(b, a, data)
    return y

def heuristic_velocity_estimator(ppg_signal, fs, sbp, dbp):
    """
    基于静态血压和 PPG 的启发式血流速度估计算法
    
    参数:
    ppg_signal: 原始 PPG 1D NumPy 数组
    fs: 采样率 (Hz)
    sbp: 静态收缩压 (mmHg)
    dbp: 静态舒张压 (mmHg)
    
    返回:
    velocity: 估算的实时血流速度数组 (cm/s)
    """
    # 1. 信号预处理：带通滤波 (0.5 Hz - 5 Hz 覆盖人类心率及主要谐波)
    clean_ppg = butter_bandpass_filter(ppg_signal, lowcut=0.5, highcut=5.0, fs=fs)
    
    # 2. 物理极值锚定 (Heuristic Anchoring)
    # 经验系数 (需根据具体测量的血管部位微调，例如指端微血管速度较低，桡动脉较高)
    # 这里我们模拟外周较粗血管，给定一个合理的转换比例
    alpha = 0.45  # SBP 到 PSV 的经验映射系数
    beta = 0.15   # DBP 到 EDV 的经验映射系数
    
    psv_target = sbp * alpha  # 估算的收缩期峰值速度 (Peak Systolic Velocity)
    edv_target = dbp * beta   # 估算的舒张末期速度 (End Diastolic Velocity)
    
    # 3. 逐周期分析与映射 (Beat-to-Beat Mapping)
    # 找到 PPG 的所有波峰 (Systolic Peaks) 和波谷 (Diastolic Troughs)
    # peaks, _ = find_peaks(clean_ppg, distance=fs*0.5) 
    # troughs, _ = find_peaks(-clean_ppg, distance=fs*0.5)
    
    # 为了简化且保证连续性，这里采用全局归一化映射 (Global Min-Max Mapping)
    # 如果您的数据极度不稳定，可以改为基于 Peaks/Troughs 的逐周期插值映射
    ppg_min = np.min(clean_ppg)
    ppg_max = np.max(clean_ppg)
    
    # 线性投射公式: v(t) = EDV + [(PPG(t) - PPG_min) / (PPG_max - PPG_min)] * (PSV - EDV)
    velocity_cm_s = edv_target + (clean_ppg - ppg_min) * (psv_target - edv_target) / (ppg_max - ppg_min)
    
    return clean_ppg, velocity_cm_s, psv_target, edv_target

# ==========================================
# 测试执行模块
# ==========================================
if __name__ == "__main__":
    # 文件名：105舒張壓90收縮壓EarFront_ppg_data_1780049581436.csv
    # 正常人的收缩压（SBP）大于舒张压（DBP），推测 105 为 SBP，90 为 DBP
    SBP_INPUT = 105 
    DBP_INPUT = 90  
    
    csv_file = "105舒張壓90收縮壓EarFront_ppg_data_1780049581436.csv"
    
    try:
        data = pd.read_csv(csv_file)
        print(f"成功加載數據: {csv_file}")
    except FileNotFoundError:
        print(f"錯誤: 找不到檔案 {csv_file}")
        exit(1)

    # 1. 获取数据
    # 將時間從毫秒轉為秒，並從 0 開始
    t_ms = data['TimeMs'].values
    t = (t_ms - t_ms[0]) / 1000.0  
    
    # 使用 IR 光的訊號作為主要的 PPG 訊號（因為在穿戴式裝置中，IR 對於血流脈動通常有較好響應）
    ppg_raw = data['IR'].values
    
    # 動態計算實際採樣率 FS
    mean_dt = np.mean(np.diff(t))
    FS = 1.0 / mean_dt
    print(f"動態計算的採樣率 (FS): {FS:.2f} Hz")
    
    # 2. 运行启发式算法
    ppg_clean, velocity_est, psv, edv = heuristic_velocity_estimator(ppg_raw, FS, SBP_INPUT, DBP_INPUT)
    
    # 3. 将估算的血流速度存成 Excel 文件
    output_df = pd.DataFrame({
        'Time_s': t,
        'Time_ms': t_ms,
        'Raw_PPG_IR': ppg_raw,
        'Filtered_AC_PPG': ppg_clean,
        'Estimated_Velocity_cm_s': velocity_est
    })
    
    excel_filename = "Estimated_BloodFlowVelocity.xlsx"
    output_df.to_excel(excel_filename, index=False)
    print(f"血流速度數據已成功儲存為 Excel 文件: {excel_filename}")
    
    # 4. 结果可视化
    plt.figure(figsize=(12, 8))
    
    # 绘制原始与滤波后的 PPG
    ax1 = plt.subplot(2, 1, 1)
    
    # 使用雙 Y 軸以確保原始數據和濾波數據在同一圖表中都能清晰顯示，因為它們的數值範圍可能差異很大
    color1 = 'tab:gray'
    ax1.plot(t, ppg_raw, label='Raw IR PPG (with drift)', color=color1, alpha=0.6)
    ax1.set_ylabel('Raw Amplitude (a.u.)', color=color1)
    ax1.tick_params(axis='y', labelcolor=color1)
    
    ax2 = ax1.twinx()  
    color2 = 'tab:blue'
    ax2.plot(t, ppg_clean, label='Filtered AC PPG', color=color2, linewidth=1.5)
    ax2.set_ylabel('Filtered Amplitude', color=color2)
    ax2.tick_params(axis='y', labelcolor=color2)
    
    plt.title('Step 1: Signal Processing (Volume Change Proxy)')
    
    # 合併圖例
    lines1, labels1 = ax1.get_legend_handles_labels()
    lines2, labels2 = ax2.get_legend_handles_labels()
    ax2.legend(lines1 + lines2, labels1 + labels2, loc='upper right')
    ax1.grid(True, alpha=0.3)
    
    # 绘制映射后的血流速度
    plt.subplot(2, 1, 2)
    plt.plot(t, velocity_est, label='Estimated Blood Flow Velocity', color='red', linewidth=1.5)
    plt.axhline(y=psv, color='g', linestyle='--', label=f'Target PSV ({psv:.1f} cm/s)')
    plt.axhline(y=edv, color='m', linestyle='--', label=f'Target EDV ({edv:.1f} cm/s)')
    plt.title(f'Step 2: Heuristic Velocity Mapping (Anchored by BP: {SBP_INPUT}/{DBP_INPUT} mmHg)')
    plt.xlabel('Time (seconds)')
    plt.ylabel('Velocity (cm/s)')
    plt.legend(loc='upper right')
    plt.grid(True, alpha=0.3)
    
    plt.tight_layout()
    plt.savefig('blood_flow.png')
    print("圖表已生成並儲存為 blood_flow.png。")
