So far, we have considered floating-point as the unique method to deal with real values, but can we perform these computations using only integer data/operations?

Such an approach might have significant advantages:
- floating-point modules/features **could not be available** (eg, microcontrollers) or highly resource-demanding (eg, FPGA)
- computations using floating-point often require **longer latency** vs integer

For instance, we can add two numbers like 0.75 and 1.5, performing the following integer operations:
- 0.75 → 75∙10^-2 , 1.50 → 150∙10-2
-  and consequently their sum (up to a scale factor) is: 0.75 + 1.5 = 225∙10^-2

Integer operations were feasible by simply scaling up numbers by a constant factor (ie, 10^2)

### Chiedi perchè qua stiamo parlando di fixed-point se si sono utilizzati solo degli interi
La tecnica del passare al mondo degli interi con una moltiplicazione per un fattore appropriato in realtà si può applicare anche nel contesto del floating-point. Solo che in questo cosa il range dinamico molto largo porta ad avere dei fattori moltiplicativi enormi se si moltiplica un float piccolo per uno molto grande. Questo porta ad avere a sua volta degli interi che hanno bisogno di un numero di bit enorme per essere rappresentati, questo fa perdere i vantaggi del passare alla rappresentazione intera.

```
Il "difetto" dei fixed-point di avere un range dinamico limitato li rende adatti per questo tipi di rappresentazioni al contrario dei fixed-point.
```

**Takeaway**: In generale i difetti dei floating point sono i vantaggi dei fixed-point e viceversa. 



...

**issue 2**: Dopo aver scalato all operations occur with integer values, but weighting factors (fattori che moltiplicano le intensità nell'interpolazione lineare) need conventional real division :(

That’s true, but weighting factors can be computed offline, scaled up by the chosen factor, and stored in a look-up table (LUT) easily index (e.g., in this case, using the index [XP-XA]).

The advantage is twofold: all integer operations and no weight computation at run-time.


Con fixed point computation diventa possibile effettuare calcoli tra reali utilizzando solo operazioni tra interi ed alla fine scalando indietro del fatto con cui si è scalato all'inizio per eliminare la parte decimale.

**CURIOSITÀ:** Interessante anche come operazioni costose, come moltiplicazioni, possano essere precalcolate e salvate in delle LUT in (ad esempio) in una ROM. 