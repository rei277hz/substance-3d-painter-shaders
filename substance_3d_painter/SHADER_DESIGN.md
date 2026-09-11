用基础色和光照计算颜色时，用基础色线性值逐通道乘以光的线性值对吗？要不要用加法加一部分光原本的线性值？我在用Substance 3D Painter绘画，它允许我自定义一些通道以及shader

acescg_exposure_view.glsl 是我目前的方案，其中引用的两个工具分别是web/index.html（取色器）和web/decompose.html（图像分解），我觉得拓展功能

我还希望加入一个光照的颜色倾向层，这是我的新设计，帮我看看这个：
- base color：基础色
- emission color（没写错吧）：发光颜色
- user0：反射率
- user1：光照强度（-10到10档位，0.5中性）
- user2：自发光的强度，也是0.5为中性的，-10到10档的曝光值；用加法加上去
- user3：色适应，用R和G表示temp/tint，需要做到在混色时线性过渡自然，所以是不能直接用色温的K值的，要求0.5为中性，代表相对于AP1白点的相对变化

---

这个对吗？色适应应该如何保持线性？我要求比如用(0.2, 0.3, -)过渡到(0.8, 0.4, -)画渐变时，中间的过渡颜色按照色温轨迹走，而且是平滑均匀地走。有没有办法创造一个空间，其中色温轨迹是线性均匀的

--- 回答 ---

你的通道拆分基本成立。也可以建立一个让“温度轨迹变直、沿轨迹等速”的编辑空间，但需要非线性解码；它不等同于线性 RGB，也不能保证任意 Temp/Tint 渐变在所有颜色上都视觉匀速。
先回答乘法和加法的问题，再说这个空间怎样构造。
在常规 RGB 漫反射模型里，基础色与光照色确实是在同一个场景线性 RGB 空间内逐通道相乘。不需要额外固定加上一部分光源颜色。加法应当对应独立贡献，例如镜面反射、自发光或其他光源产生的反射光。Painter 的基础合成公式正是：
C=\mathrm{albedo}\odot\mathrm{diffuseShading}+\mathrm{specularShading}+\mathrm{emissive}
其中 \odot 表示逐通道乘法。Adobe Shader API⁠
例如，黑色塑料上依然能出现接近光源颜色的高光，那是镜面反射贡献。若直接使用 Base * Light + k * Light，这个额外项可以作为绘画效果，但不会自动成为正确的高光模型。
另外，RGB 逐通道乘法本身是渲染近似；严格的材质与光源相互作用发生在光谱上。你经过感知归一化的 Base Color 也没有因此成为测量得到的物理反射率，这一点你原来的说明已经区分得很好。
你的新通道可以这样明确：
通道	建议含义	中性／初始化
Base Color	原方案的参考归一化颜色 A	保留原定义
Emissive	自发光颜色 E，场景线性 ACEScg	黑色表示不发光
User0	中性灰校准的反射尺度控制 r	r=\mathrm{Refl}
User1.R	反射曝光，e_L=20u_1-10	0.5 表示乘 1
User2.R	自发光曝光，e_E=20u_2-10	0.5 表示乘 1
User3.RG	相对于 AP1 白点的 Temp/Tint 编辑坐标	(0.5,0.5)
“Emission color”这个说法没错；Painter 的通道名称是 Emissive，shader 绑定为 channel_emissive。Adobe 发光接口⁠
保留原来的 Refl 契约时，整体计算可以写成：
C_{\mathrm{scene}}=2^{e_{\mathrm{global}}}\left[\frac{r}{\mathrm{Refl}}\,F(A,W)\,2^{e_L}+E\,2^{e_E}\right]
这里 W 是 User3 解码得到的目标光色，F 是你选定的染色方式。全局曝光放在求和之后，因此同时影响反射和自发光；User1 只影响反射部分。
需要先决定的是：F 表示光照乘色，还是色适应变换。
* 若表示常规 RGB 光照：F(A,W)=A\odot L(W)，其中 L(W) 是目标白点转换得到的 ACEScg 光色。
* 若表示你说的色适应：可以使用 CAT02 或 CAT16，根据参考白点和目标白点构造一个矩阵。
以完整的 von Kries 型适应为例：
F(A,W)=P^{-1}M^{-1}\operatorname{diag}\!\left(\frac{MW}{MW_0}\right)MPA
P 是 AP1→XYZ 矩阵，M 是所选 CAT 的 XYZ→适应响应矩阵，W_0 是 AP1 白点；两个白点都用 Y=1 归一化。固定 W 后，这是对输入颜色的线性变换。Colour 色适应实现⁠
这里使用 W_0\rightarrow W，让参考中性灰带上目标光色。若做的是把偏色光照校正回中性，方向则相反。
两种方式都会把参考中性灰染成目标白点，但对彩色物体的结果不同。不要应用 CAT 后，又乘一次相同意图的光色，否则会重复染色。白点采用 Y=1 也只校准中性灰，不保证所有彩色像素的亮度或 J_{\mathrm{HK}} 不变。
你希望的渐变，关键在于：让 User3 保存适合插值的参数，而不是要求“参数→光色”的解码也是线性的。
最简单的改进是存倒色温：
m=\frac{10^6}{T}\qquad\text{（mired）}
线性插值 m，再转换回温度并求轨迹上的颜色，可以避免直接插值 K 值造成的明显速度不均。不过，mired 并不等于严格的轨迹弧长。
我用 Krystek 的黑体轨迹近似计算了下面的对比。曲线斜率越恒定，表示渐变前进时，沿轨迹移动得越均匀；这里衡量的是 CIE 1960 uv 中的距离。计算依据⁠
要进一步满足你的要求，可以建立一个“沿温度轨迹的位置＋偏离轨迹的距离”的二维坐标。这是针对绘画的自定义参数化。
先处理 AP1 中性点。它的精确白点是：
(x_0,y_0)=(0.32168,\;0.33767)
它接近 6000 K 的日光白，但既不在黑体轨迹上，也不精确落在日光轨迹上。因此不能直接用“6000 K 黑体、零偏移”充当恒等变换。ACES 白点说明⁠
可以这样构造：
1. 将 AP1 白点转换到 CIE 1960 uv，求出它的 T_0 和 d_0=D_{uv}(W_0)。
2. 用 G 保存相对于 d_0 的偏移：d=d_0+D(2G-1)其中 D 决定 Tint 范围。
3. 对每个固定 d，建立对应的温度曲线：\gamma_d(T)=\operatorname{CCTDuvToUv}(T,d)
4. 沿这条曲线累计弧长，并以 T_0 为零点：a_d(T)=\int_{T_0}^{T}\left\|\frac{\partial\gamma_d(\tau)}{\partial\tau}\right\|\,d\tau
5. 让 R 线性表示这个弧长：T=a_d^{-1}\!\big(S(2R-1)\big)
S 控制温度方向的范围。最后通过 \gamma_d(T) 得到目标白点，转换到 Y=1 的 XYZ，再生成光色或 CAT 矩阵。CCT 与 D_{uv} 联合描述光色已有成熟方法可用。NIST：CCT 与 Duv⁠
这样构造有几个明确性质：
* (0.5,0.5) 对应精确 AP1 白点，变换为恒等。
* 固定 G 时，R 的等量变化对应所选 uv 曲线上的等量弧长。
* G 线性控制相对 D_{uv}，中间值不会经过 gamma 或色温 K 值插值。
* 此公式中 R 增大对应更高温度；想让 R 增大表示更暖，翻转弧长的符号即可。
这里 G=0.5 对应的是“保持 AP1 白点自身 D_{uv} 的温度曲线”。真正的黑体轨迹是 d=0，因此它不会恰好位于 G=0.5。这是精确 AP1 中性点要求带来的必然结果。
实现时可以离线生成二维 LUT：User3.RG → 相对于 AP1 白点的 CIE 1960 `delta uv`。每个固定 G 的温度曲线分别按弧长重采样，shader 只负责查表、恢复 Y=1 的 XYZ 并执行 CAT16。有限分辨率 LUT 会有插值误差，但不需要逐像素做积分或迭代求解。
还有一个范围上的约束：若要求 0.5 是中性，而且两侧严格同速，就需要使用同一个 S。不能再任意指定暖端、冷端温度；如果把两侧分别拉伸到不同端点，中性位置通常会出现速度变化。
对你举的例子：
(R,G)(t)=(0.2+0.6t,\;0.3+0.1t)
中点确实是 (0.5,0.35)。这表示温度回到参考位置，但 Tint 仍有偏移，所以中点并不是中性色。
而且这段渐变同时改变温度和 Tint，走过的是跨越多条固定 Tint 曲线的路径。上面的构造保证了各条固定 Tint 轨迹的等速，却不保证这条二维路径也等速。若要让某一对端点之间的完整路径严格等速，需要对那条路径再次按距离重采样；普通的 RG 线性混合无法为所有端点组合同时保证这一点。
最后，“在 uv 中等距”和“经过 ACES 后看起来等距”还需要分开。若你真正关心的是后者，可以固定 ACES view、参考灰亮度、曝光和观察条件，在输出后的颜色上用选定的感知色差度量累计弧长，再生成 LUT。你现有的 J_{\mathrm{HK}} 等亮约束本身不足以定义颜色之间的完整距离；可以另选 CAM16-UCS 等度量。这样得到的是针对该观看条件和参考样本的均匀性，无法保证所有基础色和曝光下都同样均匀。
Painter 中落地时，我会特别注意这几项：
* User3 使用 RGB16F，并关闭 “Color channel”。 存储格式和色彩管理开关是两件事，单纯改成 RGB16F 不代表数据不会被色彩管理。Adobe 通道设置⁠
* 用正常的不透明度混合这些原始参数，先得到混合后的 RG，再在 shader 中解码；不要先转成 RGB 光色再混合。
* User1、User2 可使用原始数据的 L16F。两者的 0.5 都表示乘 1；自发光彻底关闭应依靠黑色 Emissive 或独立遮罩，−10 EV 仍然不等于零。
* 原方案中 User1 的反射曝光内容保留在新 shader 的 User1；User2 保存新的自发光曝光。新增的场景侧 CAT 也不等价于你调色板原有的“显示侧 CAT02＋J_{\mathrm{HK}} 保亮”。
此外，两束光真正按能量混合时，应在线性 RGB／XYZ 中加权相加，结果通常会离开黑体轨迹。你希望的“沿温度轨迹画渐变”属于光色参数的插值，作为绘画控制完全合理。

---

实现版本
--------

实现文件为 `acescg_white_balance_view.glsl`，LUT 由
`generate_whitepoint_lut.py` 生成，默认输出 `whitepoint_cct_duv_lut.exr` 和
`lut-manifest.json`。旧的 `acescg_exposure_view.glsl` 保持不变。

固定实现决定如下：

* 渲染模型是 unlit；Painter 负责最终的 OCIO/view 输出变换。
* User3 `(0.5,0.5)` 是精确 AP1/D60 中性点，shader 直接绕过 CAT16 算术。
* CAT16 从 AP1/D60 适应到 LUT 白点，并作用于反射与发光相加后的总和。
* User3.R 沿固定 signed-Duv 的 CIE 1960 uv 曲线按严格弧长编码；User3.G
  使用相对于 AP1 anchor 的 Duv，范围为 `reference_Duv +/- 0.02`。
  保留现有方向：R=0 是低温/偏暖侧，R=1 是高温/偏冷侧。
* LUT 是 257x257 RGB32F 原始数据：R=`u-AP1_u`，G=`v-AP1_v`，B=0。
  生成器使用 CIE 1931 2-degree 光谱 Planck 积分（360--830 nm、1 nm、梯形端点）
  和 SciPy `brentq` 求 AP1 anchor。所有固定-Duv 行共享围绕 anchor 的对称弧长范围。
* shader 用 `textureSize` 拒绝非 257x257 资源，用 level-0 `texelFetch` 手动双线性插值，
  并把坐标夹到 `[0,1]`，因此 0/1 不会跨到纹理另一侧。LUT 必须是 raw/linear、无 mipmap
  和色彩管理；坐标和 LUT payload 都在 shader 中作为数据处理。

通道和缺省值如下：

    Base Color  = scene-linear ACEScg/AP1；缺省 (Refl, Refl, Refl)
    Emissive    = scene-linear ACEScg/AP1；缺省 (0, 0, 0)
    User0.R     = 反射率尺度 r；缺省 0.5（与 Refl 无关）
    User1.R     = 反射曝光编码；缺省 0.5，EV=20*clamp(R,0,1)-10
    User2.R     = 发光曝光编码；缺省 0.5，EV=20*clamp(R,0,1)-10
    User3.RG    = LUT 坐标；缺省 (0.5,0.5)
    User3.B     = 存在通道的完整性标记；存在时必须严格等于 0.5

存在的 User3 若含非有限 RGB 或 B 不等于 0.5，则输出不透明黑；不存在的 User3
表示中性。`User0<0` 夹到零，`Refl<=0` 只关闭反射项，Global EV 夹到 +/-10，
最终有限的有符号 RGB 不夹到 0..1。任何非有限输入、中间值或结果均输出不透明黑。

    reflected = BaseColor * (max(User0,0) / Refl) * 2^(20*clamp(User1,0,1)-10)
    emitted   = Emissive * 2^(20*clamp(User2,0,1)-10)
    scene     = CAT16(reflected + emitted) * 2^clamp(Global,-10,10)

Painter 中 User0--User3 应关闭 Color channel 并作为 raw data 混合；先混合 User3.RG，
再查 LUT，不能先把白点解码成 RGB 再混合。`validate_shader.py` 会在 Mesa standalone EGL
中编译、链接并渲染实际 shader，通过最小 Painter API adapter 检查上述契约；它不代表
Substance 3D Painter 应用集成测试。
